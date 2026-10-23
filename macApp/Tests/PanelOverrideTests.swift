import XCTest
import AppKit
import ChikaCore
import ZIPFoundation
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
        XCTAssertFalse(ReadingProgress.panelsDrawn(a, page: 2))   // not drawn by hand unless saved so
        ReadingProgress.setPanelOverride(a, page: 2, panels: [right, left], drawn: true)
        XCTAssertTrue(ReadingProgress.panelsDrawn(a, page: 2))

        ReadingProgress.setPanelOverride(a, page: 1, panels: [left])
        ReadingProgress.deletePanelOverride(a, page: 1)
        XCTAssertNil(ReadingProgress.panelOverride(a, page: 1))

        ReadingProgress.setPanelOverride(b, page: 2, panels: [left])
        ReadingProgress.clear(key: ReadingProgress.key(a))
        XCTAssertNil(ReadingProgress.panelOverride(a, page: 2))
        XCTAssertEqual(ReadingProgress.panelOverride(b, page: 2), [left])
    }

    func testOverridesListAndExportAsYoloTrainingPairs() throws {
        let a = dir.appendingPathComponent("A b.cbz"), gone = dir.appendingPathComponent("Gone.cbz")
        let b = dir.appendingPathComponent("sub/a B.cbz")   // same name but for case: one file on APFS if keyed by title
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [a, gone, b] { try FileManager.default.copyItem(at: comic, to: url) }
        ReadingProgress.setPanelOverride(a, page: 2, panels: [left, right], drawn: true)
        ReadingProgress.setPanelOverride(a, page: 0, panels: [Panel(left: 0.5, top: 0.5, right: 0.5, bottom: 1)], drawn: true)   // degenerate only
        ReadingProgress.setPanelOverride(a, page: 1, panels: [.fullPage], drawn: true)   // saved with no panels: one page-sized panel
        ReadingProgress.setPanelOverride(a, page: 99, panels: [left], drawn: true)   // past the end: the file shrank
        ReadingProgress.setPanelOverride(gone, page: 1, panels: [left], drawn: true)
        ReadingProgress.setPanelOverride(b, page: 2, panels: [left], drawn: true)
        ReadingProgress.setPanelOverride(b, page: 0, panels: [right])   // boxes left as detected: not training data

        let rows = ReadingProgress.allPanelOverrides()
        let ka = ReadingProgress.key(a), kg = ReadingProgress.key(gone), kb = ReadingProgress.key(b)
        XCTAssertEqual(rows.map { "\($0.id) \($0.page)" }.sorted(),
                       ["\(ka) 0", "\(ka) 1", "\(ka) 2", "\(ka) 99", "\(kg) 1", "\(kb) 0", "\(kb) 2"].sorted())
        XCTAssertEqual(rows.first { $0.id == ka && $0.page == 2 }?.panels, [left, right])
        XCTAssertEqual(rows.first { $0.id == kb && $0.page == 0 }?.drawn, false)

        let out = dir.appendingPathComponent("export")
        let result = try TrainingExport.export(rows, comics: [ka: a, kb: b], to: out)
        XCTAssertEqual(result.pages, 3)
        XCTAssertEqual(result.missing, 1)
        XCTAssertEqual(result.failed, 1)   // page 99
        XCTAssertEqual(result.undrawn, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("labels/train").path)
        XCTAssertEqual(names.count, 3)
        let name = try XCTUnwrap(names.first { $0.hasPrefix("chika_A_b_") && $0.hasSuffix("_p003.txt") }).dropLast(4)
        XCTAssertEqual(name.count, "chika_A_b_12345678_p003".count)   // the titles clash, so each carries its id
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("labels/train/" + name.replacingOccurrences(of: "_p003", with: "_p002.txt")), encoding: .utf8),
                       "0 0.500000 0.500000 1.000000 1.000000\n")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("labels/train/\(name).txt"), encoding: .utf8),
                       "0 0.250000 0.500000 0.500000 1.000000\n0 0.750000 0.500000 0.500000 1.000000\n")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("images/train/\(name).jpg")),
                       try CbzArchive(url: a).readPage(2))   // JPEG pages are copied as they are
    }

    func testExportShortensATitleTooLongForTheFileName() throws {
        let long = dir.appendingPathComponent(String(repeating: "a", count: 240) + ".cbz")   // a valid name
        try FileManager.default.copyItem(at: comic, to: long)
        ReadingProgress.setPanelOverride(long, page: 2, panels: [left], drawn: true)
        let out = dir.appendingPathComponent("export")
        let result = try TrainingExport.export(ReadingProgress.allPanelOverrides(), comics: [ReadingProgress.key(long): long], to: out)
        XCTAssertEqual(result.pages, 1)
        let name = "chika_" + String(repeating: "a", count: 200) + "_p003"   // no clash, so no id
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("images/train/\(name).jpg").path))
    }

    func testExportReencodesAPngPageAsJpeg() throws {
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                 samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
        let url = dir.appendingPathComponent("Png.cbz")
        try Archive(url: url, accessMode: .create).addEntry(with: "001.png", type: .file, uncompressedSize: Int64(png.count)) {
            png.subdata(in: Int($0)..<Int($0) + $1)
        }
        ReadingProgress.setPanelOverride(url, page: 0, panels: [left], drawn: true)
        let out = dir.appendingPathComponent("export")
        let result = try TrainingExport.export(ReadingProgress.allPanelOverrides(), comics: [ReadingProgress.key(url): url], to: out)
        XCTAssertEqual(result.pages, 1)
        XCTAssertTrue(try Data(contentsOf: out.appendingPathComponent("images/train/chika_Png_p001.jpg")).starts(with: [0xFF, 0xD8, 0xFF]))
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

        // Reset forgets the edit and detects the page again (the detector needs the page's image), or
        // takes the detection the background pre-detection already stored.
        while model.image == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        // A reset the database cannot take keeps the edit, which would otherwise come back on reopening.
        let saved = ReadingProgress.databaseURL, blocker = dir.appendingPathComponent("file")
        try Data().write(to: blocker)
        ReadingProgress.databaseURL = blocker.appendingPathComponent("progress.sqlite")   // under a file: cannot open
        XCTAssertFalse(model.resetPanels(page: 0))
        XCTAssertTrue(model.pageEdited)
        ReadingProgress.databaseURL = saved
        XCTAssertTrue(model.resetPanels(page: 0))
        XCTAssertFalse(model.pageEdited)
        XCTAssertNil(ReadingProgress.panelOverride(comic, page: 0))
        let landed = Date.now + 20   // wait for it, so it cannot land during a later test
        while model.detecting, Date.now < landed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.detecting)
        XCTAssertNotNil(model.slots.regions)
        XCTAssertNotNil(ReadingProgress.detection(comic, page: 0, rtl: true, revision: ReadingProgress.revision(comic)))   // stored for the flipped direction too
    }
}
