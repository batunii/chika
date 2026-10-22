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
        let store = LibraryStore(directory: dir)
        await store.importComic(from: comic).value
        await store.importComic(from: comic).value

        XCTAssertNil(store.importError)
        XCTAssertEqual(try files(), ["SyntheticManga 2.cbz", "SyntheticManga.cbz"])
        XCTAssertEqual(store.comics.count, 2)
        XCTAssertFalse(store.importing)
    }

    func testImportingANonArchiveFailsAndAddsNothing() async throws {
        let store = LibraryStore(directory: dir)
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

        _ = LibraryStore(directory: dir)   // migrates on first run
        let renamed = dir.appendingPathComponent("New.cbz")
        try FileManager.default.moveItem(at: dir.appendingPathComponent("Old.cbz"), to: renamed)

        XCTAssertEqual(ReadingProgress.get(renamed), legacy["Old.cbz"])
        ReadingProgress.set(renamed, page: 4, step: -1, total: 8, rtl: false)
        XCTAssertEqual(ReadingProgress.all()[ReadingProgress.key(renamed)]?.page, 4)
    }
}
