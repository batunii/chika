import XCTest
import ChikaCore
@testable import Chika

@MainActor
final class ReaderAdvanceTests: XCTestCase {
    private let comic = Bundle(for: ReaderAdvanceTests.self).url(forResource: "SyntheticManga", withExtension: "cbz")!

    override func setUp() async throws {
        ReadingProgress.defaults = UserDefaults(suiteName: "chika.tests")!   // never the real app settings
        ReadingProgress.databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
    }

    override func tearDown() async throws {
        ReadingProgress.defaults.removePersistentDomain(forName: "chika.tests")
        ReadingProgress.defaults = .standard
        for suffix in ["", "-wal", "-shm"] {   // WAL mode keeps two side files next to the database
            try? FileManager.default.removeItem(atPath: ReadingProgress.databaseURL.path + suffix)
        }
    }

    // Peek auto-advance stops on .blocked, so in Scroll and Two pages it must mean the end of the book.
    func testAdvanceIsBlockedOnlyAtTheEnds() async throws {
        // Saved in Scroll so the model opens without running panel detection (3 pages: spreads [0] [1,2]).
        ReadingProgress.set(comic, page: 0, step: -1, total: 3, rtl: false, mode: "scroll")
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        let deadline = Date.now + 10
        while model.state == .loading, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.state, .ready)

        XCTAssertEqual(model.advance(by: -1), .blocked)
        XCTAssertEqual(model.advance(by: 1), .nextPage)
        XCTAssertEqual(model.advance(by: 1), .nextPage)
        XCTAssertEqual(model.advance(by: 1), .blocked)

        model.setMode(.spread)   // on page 2: the last spread
        XCTAssertEqual(model.advance(by: 1), .blocked)
        XCTAssertEqual(model.advance(by: -1), .previousPage)
        XCTAssertEqual(model.slots.page, 0)
    }

    // A bookmark jump frames its panel only once that page's image lands, never on the page still showing.
    func testABookmarkJumpWaitsForItsPageBeforeFramingThePanel() async throws {
        let left = Panel(left: 0, top: 0, right: 0.5, bottom: 1), right = Panel(left: 0.5, top: 0, right: 1, bottom: 1)
        ReadingProgress.set(comic, page: 0, step: -1, total: 3, rtl: false, mode: "panels")
        for page in 0..<3 { ReadingProgress.setPanelOverride(comic, page: page, panels: [left, right]) }   // known panels, no detection
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        let deadline = Date.now + 10
        while model.state == .loading, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.state, .ready)

        model.goToPage(2, step: 1)
        XCTAssertEqual(model.slots.camera, .fullPage)
        while model.slots.regions == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.slots.camera, right)
        XCTAssertEqual(model.here, Bookmark(page: 2, step: 1))
    }

    // Copy, Export and peek auto-advance hold back while a page loads, so none of them uses the previous page.
    func testCopyAndAutoAdvanceWaitForTheNewPage() async throws {
        let left = Panel(left: 0, top: 0, right: 0.5, bottom: 1), right = Panel(left: 0.5, top: 0, right: 1, bottom: 1)
        ReadingProgress.set(comic, page: 0, step: -1, total: 3, rtl: false, mode: "panels")
        for page in 0..<3 { ReadingProgress.setPanelOverride(comic, page: page, panels: [left, right]) }   // no detection
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        let deadline = Date.now + 10
        while model.waitingForPage, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(model.readingImage())

        model.goToPage(1)
        XCTAssertNotNil(model.slots.regions)   // the edited panels apply at once…
        XCTAssertTrue(model.waitingForPage)    // …but the page's image is still loading
        XCTAssertNil(model.readingImage())
        XCTAssertTrue(model.copyItems(peek: true).isEmpty)
        while model.waitingForPage, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(model.readingImage())
        XCTAssertEqual(model.copyItems(peek: true).count, 1)

        model.goToPage(2)
        while model.waitingForPage, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<3 { XCTAssertEqual(model.advance(by: 1), .moved) }   // panel 1, panel 2, the outro
        XCTAssertEqual(model.advance(by: 1), .blocked)
        XCTAssertFalse(model.waitingForPage)   // the end of the book: auto-advance stops
    }

    // In Two pages any bookmark on the spread is here, so ⌘D removes it instead of adding a second one.
    func testABookmarkOnTheSpreadCountsAsHere() async throws {
        ReadingProgress.set(comic, page: 2, step: -1, total: 3, rtl: false, mode: "spread")
        ReadingProgress.toggleBookmark(comic, page: 2, step: 1)   // a panel on the spread's second page
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        let deadline = Date.now + 10
        while model.state == .loading, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.visiblePages, [1, 2])

        XCTAssertEqual(model.marksHere, [Bookmark(page: 2, step: 1)])
        model.toggleBookmark()
        XCTAssertEqual(model.bookmarks, [])
        model.toggleBookmark()
        XCTAssertEqual(model.bookmarks, [Bookmark(page: 1, step: -1)])
    }
}
