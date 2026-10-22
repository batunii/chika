import XCTest
@testable import Chika

final class CopyPanelTests: XCTestCase {
    private func solid(_ red: CGFloat, _ blue: CGFloat, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // A two-page spread copies as one image: pages in the given order, the shorter scaled up to the taller.
    func testSideBySideJoinsPagesInOrderAtOneHeight() throws {
        let red = solid(1, 0, width: 100, height: 200)
        let blue = solid(0, 1, width: 50, height: 100)   // half size: scaled to 100x200
        let joined = try XCTUnwrap(ReaderModel.sideBySide([red, blue]))
        XCTAssertEqual([joined.width, joined.height], [200, 200])

        let bytes = try XCTUnwrap(CFDataGetBytePtr(joined.dataProvider?.data))
        let rgb = { (x: Int) in [0, 1, 2].map { bytes[100 * joined.bytesPerRow + x * 4 + $0] } }
        XCTAssertEqual(rgb(50), [255, 0, 0])    // left: the first page
        XCTAssertEqual(rgb(150), [0, 0, 255])   // right: the second
        XCTAssertNil(ReaderModel.sideBySide([]))
    }
}
