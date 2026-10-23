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
        await store.importComic(from: fake).value

        XCTAssertEqual(store.importError?.components(separatedBy: "\n").count, 2)   // both failures are said, not just the last
        XCTAssertEqual(try files(), [])
        XCTAssertTrue(store.comics.isEmpty)
    }

    func testImportingAFolderWithNoPagesOfItsOwnImportsEachComicInIt() async throws {
        let root = dir.appendingPathExtension("series"), empty = dir.appendingPathExtension("empty")
        defer { for folder in [root, empty] { try? FileManager.default.removeItem(at: folder) } }
        _ = try makeImageFolder(root.appendingPathComponent("Chapter 2"))
        try FileManager.default.copyItem(at: comic, to: root.appendingPathComponent("One.cbz"))
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)

        await store.importComic(from: root).value
        XCTAssertNil(store.importError)
        XCTAssertEqual(try files(), ["Chapter 2.cbz", "One.cbz"])

        await store.importComic(from: empty).value
        XCTAssertEqual(store.importError, "Couldn't import \(empty.lastPathComponent): No comics or images found in this folder.")
    }

    func testOpenWithReadsAComicTheLibraryHasAndImportsAnyOtherFirst() async throws {
        let folder = dir.appendingPathExtension("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: comic, to: folder.appendingPathComponent("One.cbz"))
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        store.addInPlace(folder)
        var read: [URL] = []

        XCTAssertNil(store.open(fromFinder: folder.appendingPathComponent("One.cbz")) { read.append($0) })
        XCTAssertEqual(read, store.comics)   // the comic read in place, not a new copy
        XCTAssertEqual(try files(), [])

        await store.open(fromFinder: comic) { read.append($0) }?.value
        XCTAssertEqual(try files(), ["SyntheticManga.cbz"])
        XCTAssertEqual(read.last, dir.appendingPathComponent("SyntheticManga.cbz"))
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

    func testTheTestHostNeitherReopensNorRecordsTheSession() async throws {
        XCTAssertTrue(LibraryStore.hostingTests)   // so the app hosting these tests leaves the user's session alone
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: comic).value
        let x = try XCTUnwrap(store.comics.first)
        store.readerOpened(x)
        let saved = ReadingProgress.defaults.stringArray(forKey: "chika.openComics.v1")

        let host = LibraryStore(directory: dir, defaults: ReadingProgress.defaults, keepsSession: false)
        XCTAssertEqual(host.takeComicsToReopen(), [])
        host.readerOpened(x)
        host.readerClosed(x)
        XCTAssertEqual(ReadingProgress.defaults.stringArray(forKey: "chika.openComics.v1"), saved)
    }

    func testARenamedComicStillReopens() async throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: comic).value
        store.readerOpened(try XCTUnwrap(store.comics.first))
        let renamed = dir.appendingPathComponent("Renamed.cbz")
        try FileManager.default.moveItem(at: try XCTUnwrap(store.comics.first), to: renamed)

        let reopened = LibraryStore(directory: dir, defaults: ReadingProgress.defaults).takeComicsToReopen()
        XCTAssertEqual(reopened.map(\.lastPathComponent), ["Renamed.cbz"])
    }

    func testASessionWhoseComicsAreAllGoneIsClearedAtLaunch() async throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: comic).value
        let x = try XCTUnwrap(store.comics.first)
        store.readerOpened(x)
        try FileManager.default.removeItem(at: x)

        _ = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)   // launch with no library window
        XCTAssertEqual(ReadingProgress.defaults.stringArray(forKey: "chika.openComics.v1"), [])
    }

    func testReopeningAtLaunchLeavesTheLastOpenedComicAlone() async throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        for _ in 0..<2 { await store.importComic(from: comic).value }
        let x = try XCTUnwrap(store.comics.first { $0.lastPathComponent == "SyntheticManga.cbz" })
        let y = try XCTUnwrap(store.comics.first { $0.lastPathComponent == "SyntheticManga 2.cbz" })
        store.readerOpened(y)
        store.readerOpened(x)
        ReadingProgress.markOpened(y)   // y read last, x's window opened last

        let relaunched = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        let last = { LibraryStore.lastOpened(relaunched.comics, keys: relaunched.keys, opened: ReadingProgress.openedMap()) }
        XCTAssertEqual(last(), y)
        for url in relaunched.takeComicsToReopen() { relaunched.readerOpened(url) }   // their windows appear
        XCTAssertEqual(last(), y)
        relaunched.readerOpened(x)   // opened again by the user: that counts
        XCTAssertEqual(last(), x)
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

        ReadingProgress.clear(key: ReadingProgress.key(a))
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
        XCTAssertEqual(ReadingProgress.detection(a, page: 2, rtl: false, revision: ReadingProgress.revision(a), version: 1)?.regions, [left, right])
        XCTAssertEqual(ReadingProgress.detection(a, page: 2, rtl: true, revision: ReadingProgress.revision(a), version: 1)?.regions, [right, left])
        XCTAssertEqual(ReadingProgress.detection(a, page: 2, rtl: true, revision: ReadingProgress.revision(a), version: 1)?.bubbles, [bubble])
        XCTAssertEqual(ReadingProgress.detectedPages(a, revision: ReadingProgress.revision(a), version: 1), [2])
        XCTAssertNil(ReadingProgress.detection(a, page: 1, rtl: false, revision: ReadingProgress.revision(a), version: 1))
        XCTAssertNil(ReadingProgress.detection(b, page: 2, rtl: false, revision: ReadingProgress.revision(b), version: 1))

        // A new detector version ignores the old rows, then replaces them.
        XCTAssertNil(ReadingProgress.detection(a, page: 2, rtl: false, revision: ReadingProgress.revision(a), version: 2))
        XCTAssertEqual(ReadingProgress.detectedPages(a, revision: ReadingProgress.revision(a), version: 2), [])
        ReadingProgress.setDetection(a, page: 2, PageDetection(leftToRight: [right], rightToLeft: [left], bubbles: []),
                                     revision: ReadingProgress.revision(a), version: 2)
        XCTAssertEqual(ReadingProgress.detection(a, page: 2, rtl: false, revision: ReadingProgress.revision(a), version: 2)?.regions, [right])
        XCTAssertNil(ReadingProgress.detection(a, page: 2, rtl: false, revision: ReadingProgress.revision(a), version: 1))

        ReadingProgress.setDetection(b, page: 0, found, revision: ReadingProgress.revision(b), version: 2)
        ReadingProgress.clear(key: ReadingProgress.key(a))
        XCTAssertEqual(ReadingProgress.detectedPages(a, revision: ReadingProgress.revision(a), version: 2), [])
        XCTAssertEqual(ReadingProgress.detectedPages(b, revision: ReadingProgress.revision(b), version: 2), [0])
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
        XCTAssertEqual(ReadingProgress.detectedPages(a, revision: ReadingProgress.revision(a)), [0])

        // A page appended in place: same inode, so same key, but another size and date.
        let handle = try FileHandle(forWritingTo: a)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 16))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: a.path)
        XCTAssertNotEqual(ReadingProgress.revision(a), old)
        XCTAssertNil(ReadingProgress.detection(a, page: 0, rtl: false, revision: ReadingProgress.revision(a)))
        XCTAssertEqual(ReadingProgress.detectedPages(a, revision: ReadingProgress.revision(a)), [])
        XCTAssertEqual(ReadingProgress.balloonTexts(a, page: 0, revision: ReadingProgress.revision(a)), [:])
        ReadingProgress.setDetection(a, page: 0, found, revision: old)   // read before the edit: dropped
        XCTAssertEqual(ReadingProgress.detectedPages(a, revision: ReadingProgress.revision(a)), [])
        XCTAssertEqual(ReadingProgress.get(a)?.page, 3)
        XCTAssertEqual(ReadingProgress.bookmarks(a), [Bookmark(page: 2, step: -1)])
        XCTAssertEqual(ReadingProgress.panelOverride(a, page: 1), [.fullPage])
    }

    func testRemovingNeverDeletesAFileOutsideTheLibraryFolder() throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        // Say a comic whose watched folder dropped it while the Remove alert was open.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cbz")
        try FileManager.default.copyItem(at: comic, to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        ReadingProgress.set(outside, page: 2, step: -1, total: 8, rtl: false, mode: "panels")

        store.delete(outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(ReadingProgress.get(outside)?.page, 2)
    }

    func testAnImportedCopyKeepsItsDataUntilItIsReallyDeleted() async throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: comic).value
        let copy = try XCTUnwrap(store.comics.first)
        let key = ReadingProgress.key(copy)
        ReadingProgress.set(copy, page: 2, step: -1, total: 8, rtl: false, mode: "panels")
        ReadingProgress.toggleBookmark(copy, page: 1, step: -1)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)   // the folder refuses the delete
        store.delete(copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertNotNil(store.importError)
        XCTAssertEqual(store.comics, [copy])
        XCTAssertEqual(ReadingProgress.get(copy)?.page, 2)
        XCTAssertEqual(ReadingProgress.bookmarks(copy), [Bookmark(page: 1, step: -1)])

        store.delete(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNil(ReadingProgress.all()[key])
    }

    func testARemovedComicsMetadataDoesNotStickToTheNextImportOfItsName() async throws {
        let staging = dir.appendingPathExtension("staging")
        defer { try? FileManager.default.removeItem(at: staging) }
        func chapter(of series: String) throws -> URL {
            let url = staging.appendingPathComponent(series).appendingPathComponent("Chapter 001.cbz")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: comic, to: url)
            try addComicInfo(to: url, "<ComicInfo><Series>\(series)</Series></ComicInfo>")
            return url
        }
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: try chapter(of: "X")).value
        await store.infoTask?.value
        let copy = try XCTUnwrap(store.comics.first)
        XCTAssertEqual(store.info[copy]?.series, "X")

        store.delete(copy)
        await store.importComic(from: try chapter(of: "Y")).value
        await store.infoTask?.value
        XCTAssertEqual(store.comics, [copy])   // the same name, so the same URL
        XCTAssertEqual(store.info[copy]?.series, "Y")
    }

    func testAComicStillBeingCopiedInIsReadAgainOnceComplete() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cbz")
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.copyItem(at: comic, to: source)
        try addComicInfo(to: source, "<ComicInfo><Series>Saga</Series></ComicInfo>")
        let bytes = try Data(contentsOf: source)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Saga.cbz")
        try bytes.prefix(bytes.count / 2).write(to: url)   // half copied: no ZIP directory yet

        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.infoTask?.value
        XCTAssertNil(store.info[url])
        let half = store.revisions[url]

        try bytes.write(to: url)
        store.refresh()   // what the copy's last FSEvents change does
        await store.infoTask?.value
        XCTAssertEqual(store.info[url]?.series, "Saga")
        XCTAssertNotEqual(store.revisions[url], half)   // so its card loads the cover again
    }

    func testAFailedProgressSaveIsReportedOnce() throws {
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        let a = dir.appendingPathComponent("A.cbz")
        try FileManager.default.copyItem(at: comic, to: a)
        ReadingProgress.set(a, page: 1, step: -1, total: 8, rtl: false, mode: "panels")
        XCTAssertNil(store.importError)

        // Reopen the database read-only, as a full disk or a denied write would leave it.
        let database = ReadingProgress.databaseURL, other = dir.appendingPathExtension("other.sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: other.path + suffix) } }
        ReadingProgress.databaseURL = other
        _ = ReadingProgress.all()   // closes the first database
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: database.path)
        ReadingProgress.databaseURL = database

        ReadingProgress.set(a, page: 2, step: -1, total: 8, rtl: false, mode: "panels")
        ReadingProgress.markOpened(a)
        XCTAssertEqual(store.importError?.components(separatedBy: "\n").count, 1)
        XCTAssertTrue(store.importError?.contains("reading progress") == true, store.importError ?? "")
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

    func testAStaleBookmarkKeepsTheBookmarksSavedAfterIt() throws {
        let a = dir.appendingPathExtension("a"), b = dir.appendingPathExtension("b"), renamed = dir.appendingPathExtension("renamed")
        defer { for folder in [a, b, renamed] { try? FileManager.default.removeItem(at: folder) } }
        for folder in [a, b] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: comic, to: folder.appendingPathComponent("One.cbz"))
        }
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        store.addInPlace(a)
        store.addInPlace(b)
        let saved = try XCTUnwrap(ReadingProgress.defaults.array(forKey: "chika.bookmarks.v1") as? [Data])
        try FileManager.default.moveItem(at: a, to: renamed)   // a's bookmark is stale from now on

        _ = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        let resaved = try XCTUnwrap(ReadingProgress.defaults.array(forKey: "chika.bookmarks.v1") as? [Data])
        XCTAssertEqual(resaved.count, 2)
        XCTAssertNotEqual(resaved[0], saved[0])   // a's was refreshed
        let relaunched = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        XCTAssertEqual(Set(relaunched.comics.map { $0.deletingLastPathComponent().lastPathComponent }),
                       [renamed.lastPathComponent, b.lastPathComponent])
    }

    func testAWatchedFolderRenamedWhileChikaRunsKeepsItsComics() throws {
        let folder = dir.appendingPathExtension("watched"), renamed = dir.appendingPathExtension("renamed")
        defer { for url in [folder, renamed] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: comic, to: folder.appendingPathComponent("One.cbz"))
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        store.addInPlace(folder)

        try FileManager.default.moveItem(at: folder, to: renamed)
        store.refresh()
        XCTAssertEqual(store.comics.map { $0.deletingLastPathComponent().lastPathComponent }, [renamed.lastPathComponent])
        let relaunched = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)   // the new place was saved
        XCTAssertEqual(relaunched.comics.map { $0.deletingLastPathComponent().lastPathComponent }, [renamed.lastPathComponent])
    }

    func testComicsAddedInPlaceSortFirstUnderRecent() async throws {
        let folder = dir.appendingPathExtension("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: comic, to: folder.appendingPathComponent("One.cbz"))
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: comic).value
        func newest() -> String? {
            LibraryStore.arrange(store.comics, query: "", sort: .recent, unreadOnly: false, keys: store.keys, progress: [:],
                                 opened: ReadingProgress.openedMap(), info: [:]).first?.comics.first?.lastPathComponent
        }
        XCTAssertEqual(newest(), "SyntheticManga.cbz")

        store.addInPlace(folder)
        XCTAssertEqual(newest(), "One.cbz")

        try FileManager.default.copyItem(at: comic, to: folder.appendingPathComponent("Two.cbz"))
        await store.refreshSoon().value   // FSEvents' rescan, off the main thread
        XCTAssertEqual(newest(), "Two.cbz")
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
        store.addInPlace(folder)
        XCTAssertEqual(store.importError, "“\(folder.lastPathComponent)” is already in your library.")

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

    private func addComicInfo(to url: URL, _ xml: String) throws {
        let data = Data(xml.utf8)
        try Archive(url: url, accessMode: .update).addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(data.count)) {
            data.subdata(in: Int($0)..<Int($0) + $1)
        }
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

    func testFolderPagesAreRegularFilesOnly() async throws {
        let folder = dir.appendingPathExtension("links").appendingPathComponent("Pages")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let pages = try makeImageFolder(folder)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("p3.jpg"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("p4.jpg"), withDestinationURL: folder.appendingPathComponent("p2.jpg"))

        XCTAssertEqual(try FolderComic.pages(in: folder).map(\.lastPathComponent), ["p2.jpg", "p10.jpg"])
        XCTAssertFalse(FolderComic.isComic(folder))   // a subfolder and a link are not pages
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        await store.importComic(from: folder).value
        XCTAssertNil(store.importError)
        let copy = try ComicOpener.open(dir.appendingPathComponent("Pages.cbz"))
        XCTAssertEqual(try (0..<copy.pageCount).map(copy.readPage), pages)
    }

    func testAnAddedFolderIsReclassifiedAsItsContentsChange() throws {
        let root = dir.appendingPathExtension("grows")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(directory: dir, defaults: ReadingProgress.defaults)
        store.addInPlace(root)
        XCTAssertEqual(store.comics, [])

        _ = try makeImageFolder(root)   // filled with images: one comic
        store.refresh()
        XCTAssertEqual(store.comics.map(\.lastPathComponent), [root.lastPathComponent])

        try FileManager.default.copyItem(at: comic, to: root.appendingPathComponent("One.cbz"))   // gains an archive: a folder of comics
        store.refresh()
        XCTAssertEqual(store.comics.map(\.lastPathComponent), ["One.cbz"])
    }

    func testComicInfoGroupsSeriesAndFindsTheNextIssue() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ name: String, number: String?) throws -> URL {
            let url = dir.appendingPathComponent("\(name).cbz")
            try FileManager.default.copyItem(at: comic, to: url)
            if let number { try addComicInfo(to: url, "<ComicInfo><Series>Saga</Series><Number>\(number)</Number></ComicInfo>") }
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

    func testAnInPlaceCb7GivesItsMetadataAndCoverWithoutAFullConversion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cb7")
        try FileManager.default.copyItem(at: try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Tiny", withExtension: "cb7")), to: url)
        let converted = ComicOpener.cacheDir.appendingPathComponent(ReadingProgress.key(url).replacingOccurrences(of: "/", with: "_"))
            .appendingPathExtension("cbz")
        defer { for file in [url, converted] { try? FileManager.default.removeItem(at: file) } }

        XCTAssertEqual(try ComicOpener.comicInfo(url)?.series, "Tiny")
        let first = try ComicOpener.firstPage(url)
        XCTAssertEqual(first.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: converted.path))   // neither converted the archive
        let opened = try ComicOpener.open(url)   // the reader does
        XCTAssertEqual(first.page, try opened.readPage(0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.path))
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
