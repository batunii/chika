import XCTest
import SQLite3
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

    func testReadersOpenAtQuitReopenOnceIfTheirComicIsStillThere() async throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        for _ in 0..<3 { await store.importComic(from: comic).value }
        let names = ["SyntheticManga.cbz", "SyntheticManga 2.cbz", "SyntheticManga 3.cbz"]
        let x = try XCTUnwrap(store.comics.first { $0.lastPathComponent == names[0] })
        let y = try XCTUnwrap(store.comics.first { $0.lastPathComponent == names[1] })
        let z = try XCTUnwrap(store.comics.first { $0.lastPathComponent == names[2] })
        store.readerOpened(z)
        store.readerOpened(x)
        store.readerOpened(y)
        store.readerClosed(y)

        let relaunched = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        XCTAssertEqual(relaunched.takeComicsToReopen(), [z, x])
        XCTAssertEqual(relaunched.takeComicsToReopen(), [])   // a second library window reopens nothing

        try FileManager.default.removeItem(at: z)
        XCTAssertEqual(LibraryStore(directory: dir, defaults: ReadingProgress.defaults).takeComicsToReopen(), [x])
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
        ReadingProgress.set(renamed, page: 4, step: -1, total: 8, rtl: false, mode: "panels")
        XCTAssertEqual(ReadingProgress.all()[ReadingProgress.key(renamed)]?.page, 4)
    }

    func testBookmarksToggleListInOrderAndClearPerComic() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("A.cbz"), b = dir.appendingPathComponent("B.cbz")
        try FileManager.default.copyItem(at: comic, to: a)
        try FileManager.default.copyItem(at: comic, to: b)

        ReadingProgress.toggleBookmark(a, page: 4, step: -1)
        ReadingProgress.toggleBookmark(a, page: 1, step: 2)
        ReadingProgress.toggleBookmark(a, page: 1, step: -1)
        ReadingProgress.toggleBookmark(b, page: 0, step: 0)
        XCTAssertEqual(ReadingProgress.bookmarks(a), [Bookmark(page: 1, step: -1), Bookmark(page: 1, step: 2), Bookmark(page: 4, step: -1)])

        ReadingProgress.toggleBookmark(a, page: 1, step: 2)   // the same spot again removes it
        XCTAssertEqual(ReadingProgress.bookmarks(a), [Bookmark(page: 1, step: -1), Bookmark(page: 4, step: -1)])

        ReadingProgress.clear(a)
        XCTAssertEqual(ReadingProgress.bookmarks(a), [])
        XCTAssertEqual(ReadingProgress.bookmarks(b), [Bookmark(page: 0, step: 0)])
    }

    func testDetectionsRoundTripPerDirectionAndAnotherVersionIsIgnored() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("A.cbz"), b = dir.appendingPathComponent("B.cbz")
        try FileManager.default.copyItem(at: comic, to: a)
        try FileManager.default.copyItem(at: comic, to: b)
        let left = Panel(left: 0, top: 0, right: 0.5, bottom: 1), right = Panel(left: 0.5, top: 0, right: 1, bottom: 1)
        let bubble = Panel(left: 0.1, top: 0.1, right: 0.2, bottom: 0.2)
        let found = PageDetection(leftToRight: [left, right], rightToLeft: [right, left], bubbles: [bubble])

        ReadingProgress.setDetection(a, page: 2, found, revision: ReadingProgress.revision(a), version: 1)
        XCTAssertEqual(ReadingProgress.detection(a, page: 2, rtl: false, version: 1)?.regions, [left, right])
        XCTAssertEqual(ReadingProgress.detection(a, page: 2, rtl: true, version: 1)?.regions, [right, left])
        XCTAssertEqual(ReadingProgress.detection(a, page: 2, rtl: true, version: 1)?.bubbles, [bubble])
        XCTAssertEqual(ReadingProgress.detectedPages(a, version: 1), [2])
        XCTAssertNil(ReadingProgress.detection(a, page: 1, rtl: false, version: 1))
        XCTAssertNil(ReadingProgress.detection(b, page: 2, rtl: false, version: 1))

        // A new detector version ignores the old rows, then replaces them.
        XCTAssertNil(ReadingProgress.detection(a, page: 2, rtl: false, version: 2))
        XCTAssertEqual(ReadingProgress.detectedPages(a, version: 2), [])
        ReadingProgress.setDetection(a, page: 2, PageDetection(leftToRight: [right], rightToLeft: [left], bubbles: []),
                                     revision: ReadingProgress.revision(a), version: 2)
        XCTAssertEqual(ReadingProgress.detection(a, page: 2, rtl: false, version: 2)?.regions, [right])
        XCTAssertNil(ReadingProgress.detection(a, page: 2, rtl: false, version: 1))

        ReadingProgress.setDetection(b, page: 0, found, revision: ReadingProgress.revision(b), version: 2)
        ReadingProgress.clear(a)
        XCTAssertEqual(ReadingProgress.detectedPages(a, version: 2), [])
        XCTAssertEqual(ReadingProgress.detectedPages(b, version: 2), [0])
    }

    func testAComicEditedInPlaceForgetsItsDetectionsButKeepsTheReadersOwnData() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("A.cbz")
        try FileManager.default.copyItem(at: comic, to: a)
        let old = ReadingProgress.revision(a)
        let found = PageDetection(leftToRight: [.fullPage], rightToLeft: [.fullPage], bubbles: [.fullPage])
        ReadingProgress.setDetection(a, page: 0, found, revision: old)
        ReadingProgress.setBalloonText(a, page: 0, box: .fullPage, text: "hi", revision: old)
        ReadingProgress.set(a, page: 3, step: 1, total: 8, rtl: false, mode: "panels")
        ReadingProgress.toggleBookmark(a, page: 2, step: -1)
        ReadingProgress.setPanelOverride(a, page: 1, panels: [.fullPage])
        XCTAssertEqual(ReadingProgress.detectedPages(a), [0])

        // A page appended in place: same inode, so same key, but another size and date.
        let handle = try FileHandle(forWritingTo: a)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 16))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: a.path)
        XCTAssertNotEqual(ReadingProgress.revision(a), old)
        XCTAssertNil(ReadingProgress.detection(a, page: 0, rtl: false))
        XCTAssertEqual(ReadingProgress.detectedPages(a), [])
        XCTAssertEqual(ReadingProgress.balloonTexts(a, page: 0), [:])
        ReadingProgress.setDetection(a, page: 0, found, revision: old)   // read before the edit: dropped
        XCTAssertEqual(ReadingProgress.detectedPages(a), [])
        XCTAssertEqual(ReadingProgress.get(a)?.page, 3)
        XCTAssertEqual(ReadingProgress.bookmarks(a), [Bookmark(page: 2, step: -1)])
        XCTAssertEqual(ReadingProgress.panelOverride(a, page: 1), [.fullPage])
    }

    func testReaderWorkLandingAfterADeleteLeavesNoRows() throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        let a = dir.appendingPathComponent("A.cbz")
        try FileManager.default.copyItem(at: comic, to: a)
        store.refresh()
        let revision = ReadingProgress.revision(a)   // what an open reader holds
        store.delete(a)
        ReadingProgress.setDetection(a, page: 0, PageDetection(leftToRight: [], rightToLeft: [], bubbles: []), revision: revision)
        ReadingProgress.setBalloonText(a, page: 0, box: .fullPage, text: "late", revision: revision)

        var db: OpaquePointer?, stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_open(ReadingProgress.databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for table in ["detections", "balloon_text"] {
            sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(stmt, 0), 0, table)
            sqlite3_finalize(stmt)
        }
    }

    func testStopWatchingAFolderStopsPredetectingAllItsComics() throws {
        let folder = dir.appendingPathExtension("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appendingPathComponent("One.cbz"), two = folder.appendingPathComponent("Two.cbz")
        try FileManager.default.copyItem(at: comic, to: one)
        try FileManager.default.copyItem(at: comic, to: two)
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        store.addInPlace(folder)
        let found = Set(store.comics)
        BookPredetector.shared.add(found.first { $0.lastPathComponent == "One.cbz" }!)
        BookPredetector.shared.add(found.first { $0.lastPathComponent == "Two.cbz" }!)

        store.delete(found.first { $0.lastPathComponent == "One.cbz" }!)
        let queued = BookPredetector.shared.waiting + [BookPredetector.shared.running?.url].compactMap { $0 }
        XCTAssertTrue(found.isDisjoint(with: queued))
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

    /// A folder holding two of the test comic's pages as p2.jpg and p10.jpg (only natural order reads p2
    /// first) and a hidden file; returns the pages' bytes in reading order.
    private func makeImageFolder(_ folder: URL) throws -> [Data] {
        let source = try ComicOpener.open(comic)
        let pages = [try source.readPage(0), try source.readPage(1)]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try pages[0].write(to: folder.appendingPathComponent("p2.jpg"))
        try pages[1].write(to: folder.appendingPathComponent("p10.jpg"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        return pages
    }

    func testAFolderOfImagesImportsAsACbzOrReadsInPlaceAsOneComic() async throws {
        let root = dir.appendingPathExtension("images")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Pages")
        let pages = try makeImageFolder(folder)
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)

        await store.importComic(from: folder).value
        XCTAssertNil(store.importError)
        XCTAssertEqual(try files(), ["Pages.cbz"])
        let copy = try ComicOpener.open(dir.appendingPathComponent("Pages.cbz"))
        XCTAssertEqual(copy.pageCount, 2)
        XCTAssertEqual(try copy.readPage(0), pages[0])

        store.addInPlace(folder)
        let inPlace = try XCTUnwrap(store.comics.first { $0.lastPathComponent == "Pages" })
        XCTAssertEqual(store.sources[inPlace], inPlace)   // one comic, not a watched folder
        let read = try ComicOpener.open(inPlace)
        XCTAssertEqual(read.pageCount, 2)
        XCTAssertEqual(try [read.readPage(0), read.readPage(1)], pages)
    }

    func testAWatchedFolderReadsASubfolderOfOnlyImagesAsOneComic() throws {
        let root = dir.appendingPathExtension("watched")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeImageFolder(root.appendingPathComponent("Pages"))
        _ = try makeImageFolder(root.appendingPathComponent("Mixed"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("Mixed/notes.txt"))
        try FileManager.default.copyItem(at: comic, to: root.appendingPathComponent("Pages/Inside.cbz"))
        try FileManager.default.copyItem(at: comic, to: root.appendingPathComponent("One.cbz"))
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)

        store.addInPlace(root)
        // Pages holds an archive too, so it is not one comic: its archive is listed instead.
        XCTAssertEqual(Set(store.comics.map(\.lastPathComponent)), ["One.cbz", "Inside.cbz"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("Pages/Inside.cbz"))
        store.refresh()
        XCTAssertEqual(Set(store.comics.map(\.lastPathComponent)), ["One.cbz", "Pages"])
        XCTAssertEqual(try ComicOpener.open(try XCTUnwrap(store.comics.first { $0.lastPathComponent == "Pages" })).pageCount, 2)
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

    func testContinueReadingAndLastOpenedFollowRecency() {
        let urls = ["done", "older", "never", "unstarted", "panel"].map { URL(fileURLWithPath: "/c/\($0).cbz") }
        let keys = Dictionary(uniqueKeysWithValues: urls.map { ($0, $0.lastPathComponent) })
        let progress = ["done.cbz": Progress(page: 9, step: -1, total: 10), "older.cbz": Progress(page: 3, step: 1, total: 10),
                        "unstarted.cbz": Progress(page: 0, step: -1, total: 10), "panel.cbz": Progress(page: 0, step: 2, total: 10)]
        let opened = ["done.cbz": 9.0, "older.cbz": 1.0, "never.cbz": 8.0, "unstarted.cbz": 7.0, "panel.cbz": 2.0]
        XCTAssertEqual(LibraryStore.continueReading(urls, keys: keys, progress: progress, opened: opened), [urls[4], urls[1]])
        XCTAssertEqual(LibraryStore.lastOpened(urls, keys: keys, opened: opened), urls[0])
        XCTAssertNil(LibraryStore.lastOpened(urls, keys: keys, opened: [:]))
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

    func testAPhase2DatabaseGainsTheModeColumnAndKeepsItsRows() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Old.cbz")
        try FileManager.default.copyItem(at: comic, to: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(ReadingProgress.databaseURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE progress(id TEXT PRIMARY KEY, page INTEGER, step INTEGER, total INTEGER, rtl INTEGER, opened REAL);
            INSERT INTO progress VALUES('\(ReadingProgress.key(url))', 2, 0, 3, 1, NULL);
            """, nil, nil, nil)
        sqlite3_close(db)

        XCTAssertEqual(ReadingProgress.get(url), Progress(page: 2, step: 0, total: 3, rtl: true, mode: nil))
        ReadingProgress.set(url, page: 2, step: -1, total: 3, rtl: true, mode: "spread")
        XCTAssertEqual(ReadingProgress.get(url)?.mode, "spread")
    }
}
