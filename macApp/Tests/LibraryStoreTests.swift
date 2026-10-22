import XCTest
import ZIPFoundation
import ChikaCore
@testable import Chika

@MainActor
final class LibraryStoreTests: XCTestCase {
    private var dir: URL!
    private let comic = Bundle(for: LibraryStoreTests.self).url(forResource: "SyntheticManga", withExtension: "cbz")!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ReadingProgress.defaults = UserDefaults(suiteName: "chika.tests")!   // never the real app settings
        ReadingProgress.databaseURL = dir.appendingPathExtension("sqlite")
    }

    override func tearDown() async throws {
        ReadingProgress.defaults.removePersistentDomain(forName: "chika.tests")
        ReadingProgress.defaults = .standard
        try? FileManager.default.removeItem(at: dir)
        for suffix in ["", "-wal", "-shm"] {   // WAL mode keeps two side files next to the database
            try? FileManager.default.removeItem(atPath: ReadingProgress.databaseURL.path + suffix)
        }
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testImportingTheSameComicTwiceKeepsBoth() async throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: comic).value
        await store.importComic(from: comic).value

        XCTAssertNil(store.importError)
        XCTAssertEqual(try files(), ["SyntheticManga 2.cbz", "SyntheticManga.cbz"])
        XCTAssertEqual(store.comics.count, 2)
        XCTAssertFalse(store.importing)
    }

    func testImportingANonArchiveFailsAndAddsNothing() async throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cbz")
        try Data("not a comic".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: fake) }

        await store.importComic(from: fake).value

        XCTAssertNotNil(store.importError)
        XCTAssertEqual(try files(), [])
        XCTAssertTrue(store.comics.isEmpty)
    }

    func testLegacyProgressMigratesAndFollowsARename() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: comic, to: dir.appendingPathComponent("Old.cbz"))
        let legacy = ["Old.cbz": Progress(page: 3, step: 1, total: 8, rtl: true)]
        ReadingProgress.defaults.set(try JSONEncoder().encode(legacy), forKey: "chika.progress.v1")

        _ = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)   // migrates on first run
        let renamed = dir.appendingPathComponent("New.cbz")
        try FileManager.default.moveItem(at: dir.appendingPathComponent("Old.cbz"), to: renamed)

        XCTAssertEqual(ReadingProgress.get(renamed), legacy["Old.cbz"])
        ReadingProgress.set(renamed, page: 4, step: -1, total: 8, rtl: false)
        XCTAssertEqual(ReadingProgress.all()[ReadingProgress.key(renamed)]?.page, 4)
    }

    func testWatchedFolderIsReadInPlaceAndNeverDeleted() throws {
        let folder = dir.appendingPathExtension("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("One.cbz")
        try FileManager.default.copyItem(at: comic, to: first)

        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        store.addInPlace(folder)
        XCTAssertNil(store.importError)
        XCTAssertEqual(store.comics.map(\.lastPathComponent), ["One.cbz"])
        XCTAssertEqual(try files(), [])   // nothing copied into the library folder

        // A new file in the folder shows up (FSEvents calls refresh; here we call it directly).
        try FileManager.default.copyItem(at: comic, to: folder.appendingPathComponent("Two.cbz"))
        store.refresh()
        XCTAssertEqual(Set(store.comics.map(\.lastPathComponent)), ["One.cbz", "Two.cbz"])

        // The bookmark survives a relaunch.
        XCTAssertEqual(LibraryStore(directory: dir, defaults: ReadingProgress.defaults).comics.count, 2)

        // Removing stops watching the folder; the user's files stay.
        store.delete(try XCTUnwrap(store.comics.first))
        XCTAssertTrue(store.comics.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testComicInfoGroupsSeriesAndFindsTheNextIssue() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ name: String, number: String?) throws -> URL {
            let url = dir.appendingPathComponent("\(name).cbz")
            try FileManager.default.copyItem(at: comic, to: url)
            guard let number else { return url }
            let xml = Data("<ComicInfo><Series>Saga</Series><Number>\(number)</Number></ComicInfo>".utf8)
            try Archive(url: url, accessMode: .update).addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(xml.count)) {
                xml.subdata(in: Int($0)..<Int($0) + $1)
            }
            return url
        }
        let ten = try make("b", number: "10"), two = try make("a", number: "2"), loose = try make("c", number: nil)

        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.infoTask?.value

        let groups = LibraryStore.seriesGroups(store.comics, info: store.info)
        XCTAssertEqual(groups.map(\.series), ["Saga", nil])
        XCTAssertEqual(groups.map(\.comics), [[two, ten], [loose]])
        XCTAssertEqual(store.nextIssue(after: two), ten)
        XCTAssertNil(store.nextIssue(after: ten))
        XCTAssertNil(store.nextIssue(after: loose))
    }

    func testArrangeSearchesSortsAndHidesFinishedComics() {
        let a = URL(fileURLWithPath: "/c/Alpha.cbz"), b = URL(fileURLWithPath: "/c/beta.cbz"), c = URL(fileURLWithPath: "/c/Gamma.cbz")
        let keys = [a: "a", b: "b", c: "c"]
        let progress = ["a": Progress(page: 9, step: -1, total: 10), "b": Progress(page: 1, step: -1, total: 10)]
        let opened = ["b": 2.0, "c": 1.0]
        let info = [c: ComicInfo(series: "Saga", writer: "Vaughan")]
        func arrange(_ query: String, _ sort: LibraryStore.Sort, unreadOnly: Bool = false) -> [URL] {
            LibraryStore.arrange([c, b, a], query: query, sort: sort, unreadOnly: unreadOnly, keys: keys,
                                 progress: progress, opened: opened, info: info).flatMap(\.comics)
        }
        XCTAssertEqual(arrange("", .title), [a, b, c])
        XCTAssertEqual(arrange("", .recent), [b, c, a])
        XCTAssertEqual(arrange("", .unread), [c, b, a])
        XCTAssertEqual(arrange("", .series), [c, a, b])   // the Saga section, then the rest
        XCTAssertEqual(arrange("", .title, unreadOnly: true), [b, c])
        XCTAssertEqual(arrange("vaughan", .title), [c])
        XCTAssertEqual(arrange("BET", .title), [b])
    }

    func testCb7ConvertsAndPdfImportsAsIs() async throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Tiny", withExtension: "cb7"))).value

        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("Strip.pdf")
        defer { try? FileManager.default.removeItem(at: pdf) }
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.fill(box.insetBy(dx: 40, dy: 40)); context.endPDFPage() }
        context.closePDF()
        await store.importComic(from: pdf).value

        XCTAssertNil(store.importError)
        XCTAssertEqual(try files(), ["Strip.pdf", "Tiny.cbz"])
        let cb7 = try XCTUnwrap(ComicOpener.open(dir.appendingPathComponent("Tiny.cbz")) as? CbzArchive)
        XCTAssertEqual(cb7.pageCount, 2)
        XCTAssertEqual(cb7.comicInfo?.series, "Tiny")   // ComicInfo.xml survives conversion

        let pages = try ComicOpener.open(dir.appendingPathComponent("Strip.pdf"))
        XCTAssertEqual(pages.pageCount, 2)
        let page = try XCTUnwrap(PageLoader.decodeSampled(data: pages.readPage(1), maxDim: 2560))
        XCTAssertEqual(page.height, 2560)   // rendered at the reader's page size
    }
}
