import XCTest
import UIKit
@testable import Chika

/// Real RAR5 archives made with `rar` (page "N.png" is N*10 px wide; `solid5.cbr` is a solid archive
/// with its entries in non-reading order) and the shipped TFLite model run for real.
final class RealArchiveAndModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestSupport.tempDir()
        let d = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext),
                      "missing fixture \(name).\(ext)")
    }

    private func widths(of cbz: URL) throws -> [Int] {
        let archive = try CbzArchive(url: cbz)
        return try (0..<archive.pageCount).map { Int(try XCTUnwrap(UIImage(data: archive.readPage($0))).size.width) }
    }

    func testRealRar5ConvertsToOrderedCbz() async throws {
        let dest = dir.appendingPathComponent("out.cbz")
        try await CbrConverter.convertToCbz(source: try fixture("rar5", "cbr"), destination: dest)
        XCTAssertEqual(try widths(of: dest), [10, 20, 30, 100, 110])
    }

    func testRealSolidRarConvertsToOrderedCbz() async throws {
        let dest = dir.appendingPathComponent("out.cbz")
        try await CbrConverter.convertToCbz(source: try fixture("solid5", "cbr"), destination: dest)
        XCTAssertEqual(try widths(of: dest), [10, 20, 30, 100, 110])
    }

    func testOversizedPageIsRefusedNotBuffered() throws {
        let zip = dir.appendingPathComponent("big.cbz")
        try TestSupport.zip(at: zip, entries: [
            ("1.png", Data(repeating: 1, count: 100)),
            ("2.png", Data(repeating: 2, count: 5_000)),
        ])
        let archive = try CbzArchive(url: zip, maxPageBytes: 1_000)
        XCTAssertEqual(try archive.readPage(0).count, 100)
        XCTAssertThrowsError(try archive.readPage(1))
    }

    func testRealModelProducesValidRegionsForBothDirections() throws {
        let detector = try XCTUnwrap(LiteRTPanelDetector(), "bundled model failed to load")
        let cbz = try fixture("SyntheticManga", "cbz")
        let archive = try CbzArchive(url: cbz)
        let image = try XCTUnwrap(PageLoader.decodeSampled(data: try archive.readPage(0), maxDim: 2560))

        for rtl in [false, true] {
            let regions = detector.zoomRegions(for: image, rightToLeft: rtl)
            XCTAssertFalse(regions.isEmpty)
            for r in regions {
                XCTAssertTrue((0...1).contains(r.left) && (0...1).contains(r.right), "x out of range: \(r)")
                XCTAssertTrue((0...1).contains(r.top) && (0...1).contains(r.bottom), "y out of range: \(r)")
                XCTAssertTrue(r.right > r.left && r.bottom > r.top, "degenerate region: \(r)")
            }
        }
    }
}
