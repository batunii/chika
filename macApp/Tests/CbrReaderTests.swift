import XCTest
import ChikaCore
import ImageIO
@testable import Chika

final class CbrReaderTests: XCTestCase {
    // libarchive reads zip too, so the CBZ fixture checks the streaming extractor against ZIPFoundation.
    func testStreamedEntriesMatchTheCbzPages() throws {
        let comic = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SyntheticManga", withExtension: "cbz"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let entries = try CbrReader.extract(at: comic, into: dir, keep: isImageEntry)
            .sorted { NaturalOrder.isOrderedBefore($0.name, $1.name) }
        let archive = try CbzArchive(url: comic)

        XCTAssertEqual(entries.count, archive.pageCount)
        XCTAssertGreaterThan(entries.count, 0)
        XCTAssertEqual(try Data(contentsOf: entries[0].file), try archive.readPage(0))
    }
}

final class PageLoaderTests: XCTestCase {
    // Scroll mode limits the short edge: a tall strip must keep its width, not shrink to a sliver.
    func testShortEdgeLimitKeepsATallStripWide() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        XCTAssertEqual(PageLoader.decodeSampled(data: data as Data, maxDim: 256, shortEdge: true)?.width, 300)
        XCTAssertLessThan(try XCTUnwrap(PageLoader.decodeSampled(data: data as Data, maxDim: 256)?.width), 300)
        // A strip over the pixel budget is halved until it fits (900k pixels → 56k at a quarter size).
        XCTAssertEqual(PageLoader.decodeSampled(data: data as Data, maxDim: 256, shortEdge: true, maxPixels: 100_000)?.width, 75)
    }
}
