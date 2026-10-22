import XCTest
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
}
