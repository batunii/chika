import XCTest
import ChikaCore
@testable import Chika

@MainActor
final class PanelOverrideTests: XCTestCase {
    private var dir: URL!
    private let comic = Bundle(for: PanelOverrideTests.self).url(forResource: "SyntheticManga", withExtension: "cbz")!
    private let left = Panel(left: 0, top: 0, right: 0.5, bottom: 1), right = Panel(left: 0.5, top: 0, right: 1, bottom: 1)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    func testOverridesRoundTripPerPageAndClearWithTheComic() throws {
        let a = dir.appendingPathComponent("A.cbz"), b = dir.appendingPathComponent("B.cbz")
        try FileManager.default.copyItem(at: comic, to: a)
        try FileManager.default.copyItem(at: comic, to: b)

        XCTAssertTrue(ReadingProgress.setPanelOverride(a, page: 2, panels: [left, right]))
        XCTAssertEqual(ReadingProgress.panelOverride(a, page: 2), [left, right])
        XCTAssertTrue(ReadingProgress.setPanelOverride(a, page: 2, panels: [right, left]))   // replaces, order kept
        XCTAssertEqual(ReadingProgress.panelOverride(a, page: 2), [right, left])
        XCTAssertNil(ReadingProgress.panelOverride(a, page: 1))

        ReadingProgress.setPanelOverride(a, page: 1, panels: [left])
        ReadingProgress.deletePanelOverride(a, page: 1)
        XCTAssertNil(ReadingProgress.panelOverride(a, page: 1))

        ReadingProgress.setPanelOverride(b, page: 2, panels: [left])
        ReadingProgress.clear(a)
        XCTAssertNil(ReadingProgress.panelOverride(a, page: 2))
        XCTAssertEqual(ReadingProgress.panelOverride(b, page: 2), [left])
    }

    // An edited page skips detection, keeps its stored order when the direction flips, and saves in place.
    func testAnEditedPageWinsOverDetection() async throws {
        ReadingProgress.set(comic, page: 0, step: -1, total: 3, rtl: false, mode: "panels")
        ReadingProgress.setPanelOverride(comic, page: 0, panels: [left, right])
        ReadingProgress.setPanelOverride(comic, page: 1, panels: [.fullPage])   // so the prefetch skips detection too
        let model = ReaderModel(comicURL: comic, settings: ChikaSettings())
        let deadline = Date.now + 10
        while model.state == .loading, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.state, .ready)

        XCTAssertEqual(model.slots.regions, [left, right])
        XCTAssertTrue(model.pageEdited)
        model.toggleDirection()
        XCTAssertEqual(model.slots.regions, [left, right])
        XCTAssertFalse(model.detecting)

        XCTAssertTrue(model.savePanels([right], page: 0))
        XCTAssertEqual(model.slots.regions, [right])
        XCTAssertEqual(ReadingProgress.panelOverride(comic, page: 0), [right])
        XCTAssertTrue(model.savePanels([], page: 0))   // nothing left: the page reads whole
        XCTAssertEqual(model.slots.regions, [.fullPage])
    }
}
