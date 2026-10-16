import XCTest
@testable import Chika

@MainActor
final class LibraryStoreTests: XCTestCase {
    private var library: URL!
    private var source: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        library = try TestSupport.tempDir()
        source = try TestSupport.tempDir()
        store = LibraryStore(directory: library)
        let (lib, src) = (library!, source!)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: lib)
            try? FileManager.default.removeItem(at: src)
        }
    }

    /// Imports run on a background queue; wait until the store reports idle.
    private func waitForImports(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<750 where store.importing { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(store.importing, "import did not finish", file: file, line: line)
    }

    private func makeBook(_ name: String, pages: Int) throws -> URL {
        let url = source.appendingPathComponent(name)
        try TestSupport.zip(at: url, entries: (1...pages).map { ("\($0).png", TestSupport.png(width: 40, height: 60)) })
        return url
    }

    private func libraryFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).sorted()
    }

    func testImportCopiesCbzIntoLibrary() async throws {
        store.importComic(from: try makeBook("Book.cbz", pages: 3))
        await waitForImports()

        XCTAssertNil(store.importError)
        XCTAssertEqual(libraryFiles(), ["Book.cbz"])
        XCTAssertEqual(store.comics.map(\.lastPathComponent), ["Book.cbz"])
        XCTAssertEqual(try CbzArchive(url: library.appendingPathComponent("Book.cbz")).pageCount, 3)
    }

    /// Regression: a same-named import used to silently overwrite the existing comic.
    func testSameNameImportKeepsBothComics() async throws {
        let first = try makeBook("Vol 1.cbz", pages: 2)
        store.importComic(from: first)
        await waitForImports()

        // A different book with the same file name, from another folder.
        let other = try TestSupport.tempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }
        let second = other.appendingPathComponent("Vol 1.cbz")
        try TestSupport.zip(at: second, entries: (1...5).map { ("\($0).png", TestSupport.png(width: 40, height: 60)) })
        store.importComic(from: second)
        await waitForImports()

        XCTAssertEqual(libraryFiles(), ["Vol 1 2.cbz", "Vol 1.cbz"])
        XCTAssertEqual(try CbzArchive(url: library.appendingPathComponent("Vol 1.cbz")).pageCount, 2, "original untouched")
        XCTAssertEqual(try CbzArchive(url: library.appendingPathComponent("Vol 1 2.cbz")).pageCount, 5)
    }

    /// Regression: a failed re-import used to delete the existing comic first.
    func testFailedImportLeavesExistingComicAndNoPartialFile() async throws {
        store.importComic(from: try makeBook("Book.cbz", pages: 2))
        await waitForImports()

        store.importComic(from: source.appendingPathComponent("does-not-exist/Book.cbz"))
        await waitForImports()

        XCTAssertNotNil(store.importError)
        XCTAssertEqual(libraryFiles(), ["Book.cbz"])
        XCTAssertEqual(try CbzArchive(url: library.appendingPathComponent("Book.cbz")).pageCount, 2)
    }

    func testMultipleImportsAllCompleteAndImportingFlagStaysUntilTheLast() async throws {
        let urls = try (1...3).map { try makeBook("Issue \($0).cbz", pages: $0) }
        urls.forEach(store.importComic)
        XCTAssertTrue(store.importing)

        await waitForImports()

        XCTAssertEqual(libraryFiles(), ["Issue 1.cbz", "Issue 2.cbz", "Issue 3.cbz"])
        XCTAssertEqual(store.comics.count, 3)
    }

    func testDeleteRemovesFileAndProgress() async throws {
        store.importComic(from: try makeBook("Gone.cbz", pages: 1))
        await waitForImports()
        let url = library.appendingPathComponent("Gone.cbz")
        ReadingProgress.set(url, page: 0, step: -1, total: 1, rtl: false)

        store.delete(url)

        XCTAssertTrue(libraryFiles().isEmpty)
        XCTAssertNil(ReadingProgress.get(url))
        XCTAssertTrue(store.comics.isEmpty)
    }
}
