import XCTest
import ImageIO
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

    // Shortcuts' Next and Previous Panel step the reader last in front, and say so when there is none.
    func testPanelShortcutsStepTheFrontReader() async throws {
        ReadingProgress.set(comic, page: 0, step: -1, total: 3, rtl: false, mode: "scroll")   // no detection
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        let deadline = Date.now + 10
        while model.state == .loading, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let other = ReaderModel(comicURL: comic, settings: ChikaSettings())

        ShortcutTarget.windowOpened(model)
        ShortcutTarget.windowOpened(other)
        ShortcutTarget.windowActivated(model)   // the first window back in front
        _ = try await NextPanelIntent().perform()
        XCTAssertEqual(model.slots.page, 1)
        _ = try await PreviousPanelIntent().perform()
        XCTAssertEqual(model.slots.page, 0)

        // Closing it falls back to the other window; closing that leaves none, though both models live on here.
        ShortcutTarget.windowClosed(model)
        XCTAssertTrue(ShortcutTarget.reader === other)
        ShortcutTarget.windowClosed(other)
        XCTAssertNil(ShortcutTarget.reader)
        do { _ = try await NextPanelIntent().perform(); XCTFail("stepped with no reader") } catch is ShortcutError {}
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

    // ⌘1-3 while the comic opens would save the placeholder page 1 over the real position.
    func testAModeChangeWhileOpeningKeepsTheSavedPage() async throws {
        ReadingProgress.set(comic, page: 2, step: -1, total: 3, rtl: false, mode: "scroll")
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        model.setMode(.spread)
        let deadline = Date.now + 10
        while model.state == .loading, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.mode, .scroll)
        XCTAssertEqual(model.slots.page, 2)
        XCTAssertEqual(ReadingProgress.get(comic)?.page, 2)
    }

    // A page's known panels apply as its turn starts, but stepping onto one waits for the page's image.
    func testPanelsOfAPageStillLoadingWaitForItsImage() async throws {
        let left = Panel(left: 0, top: 0, right: 0.5, bottom: 1), right = Panel(left: 0.5, top: 0, right: 1, bottom: 1)
        ReadingProgress.set(comic, page: 0, step: -1, total: 3, rtl: false, mode: "panels")
        for page in 0..<3 { ReadingProgress.setPanelOverride(comic, page: page, panels: [left, right]) }   // no detection
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        let deadline = Date.now + 10
        while model.state != .ready || model.waitingForPage, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        model.goToPage(1)
        XCTAssertEqual(model.advance(by: 1), .blocked)   // page 1's first panel, with page 0's image still on screen
        XCTAssertEqual(model.slots.step, -1)
        while model.waitingForPage, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.advance(by: 1), .moved)
        XCTAssertEqual(model.slots.camera, left)

        model.goToPage(2)
        XCTAssertEqual(model.advance(by: -1), .previousPage)   // turning a page is fine while one loads
    }

    // Flipping the direction while a page loads must land that page's panels in the new order.
    func testADirectionFlipDuringALoadReordersThePanels() async throws {
        let left = Panel(left: 0, top: 0, right: 0.5, bottom: 1), right = Panel(left: 0.5, top: 0, right: 1, bottom: 1)
        ReadingProgress.set(comic, page: 0, step: -1, total: 3, rtl: false, mode: "panels")
        let detection = PageDetection(leftToRight: [left, right], rightToLeft: [right, left], bubbles: [])
        for page in 0..<3 { ReadingProgress.setDetection(comic, page: page, detection, revision: ReadingProgress.revision(comic)) }
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        let deadline = Date.now + 10
        while model.state != .ready || model.waitingForPage, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        model.goToPage(1)
        XCTAssertEqual(model.slots.regions, [left, right])
        model.toggleDirection()
        while model.waitingForPage, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.slots.regions, [right, left])
    }

    // Two pages steps from the spread on screen, so a double page found on the way back is shown, not skipped.
    func testTwoPagesNeverSkipsAPageAroundADoublePageFoundLate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for page in 0..<8 {   // page 4 (0-based) is a scanned double page: wider than tall
            let context = try XCTUnwrap(CGContext(data: nil, width: page == 4 ? 30 : 20, height: page == 4 ? 20 : 30,
                                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let url = folder.appendingPathComponent("\(page + 1).png") as CFURL
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        ReadingProgress.set(folder, page: 6, step: -1, total: 8, rtl: false, mode: "spread")
        let model = ReaderModel(comicURL: folder, settings: ChikaSettings())
        let deadline = Date.now + 10
        func settle() async throws {
            while model.state != .ready || model.waitingForPage, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
        try await settle()
        XCTAssertEqual(model.visiblePages, [5, 6])

        var seen: [[Int]] = []
        for delta in [-1, -1, -1, 1, 1, 1] {
            model.advance(by: delta)
            try await settle()
            seen.append(model.visiblePages)
        }
        XCTAssertEqual(seen, [[4], [3], [1, 2], [3], [4], [5, 6]])
    }
}
