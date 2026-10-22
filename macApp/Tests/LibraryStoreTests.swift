import XCTest
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
        try? FileManager.default.removeItem(at: ReadingProgress.databaseURL)
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
}
