import XCTest
import UIKit
@testable import Chika

final class ReadingProgressTests: XCTestCase {
    private func comicURL() -> URL {
        URL(fileURLWithPath: "/tmp/\(UUID().uuidString).cbz")
    }

    func testProgressRoundTripAndClear() {
        let url = comicURL()
        XCTAssertNil(ReadingProgress.get(url))

        ReadingProgress.set(url, page: 4, step: 2, total: 10, rtl: true)
        let p = ReadingProgress.get(url)
        XCTAssertEqual(p?.page, 4)
        XCTAssertEqual(p?.step, 2)
        XCTAssertEqual(p?.total, 10)
        XCTAssertEqual(p?.percent, 44)   // 4 / (10 - 1)

        ReadingProgress.clear(url)
        XCTAssertNil(ReadingProgress.get(url))
    }

    func testDirectionIsPerComicWithGlobalFallback() {
        let url = comicURL()
        defer { ReadingProgress.clear(url) }
        let saved = ReadingPrefs.defaultRightToLeft
        defer { ReadingPrefs.defaultRightToLeft = saved }

        ReadingPrefs.defaultRightToLeft = true
        XCTAssertTrue(ReadingProgress.readingDirection(url), "unset comic follows the global default")

        ReadingProgress.set(url, page: 0, step: -1, total: 1, rtl: false)
        XCTAssertFalse(ReadingProgress.readingDirection(url), "the comic's own choice wins")
    }

    func testMarkOpenedDrivesRecencyOrder() {
        let a = comicURL(), b = comicURL()
        defer { ReadingProgress.clear(a); ReadingProgress.clear(b) }
        XCTAssertEqual(ReadingProgress.openedAt(a), 0)
        ReadingProgress.markOpened(a)
        XCTAssertGreaterThan(ReadingProgress.openedAt(a), ReadingProgress.openedAt(b))
    }
}

final class PageLoaderDecodeTests: XCTestCase {
    private func longEdge(of image: UIImage?) throws -> Int {
        let cg = try XCTUnwrap(image?.cgImage)
        return max(cg.width, cg.height)
    }

    func testSmallPageIsNotDownsampled() throws {
        let data = TestSupport.png(width: 1000, height: 1500)
        XCTAssertEqual(try longEdge(of: PageLoader.decodeSampled(data: data, maxDim: 2560)), 1500)
    }

    /// Pins the cross-platform sampling rule (identical to Android's): power-of-two steps that keep
    /// the long edge >= maxDim, so a 6000px page halves to 3000 rather than shrinking to 2560.
    func testLargePageUsesPowerOfTwoSampling() throws {
        let data = TestSupport.png(width: 4000, height: 6000)
        XCTAssertEqual(try longEdge(of: PageLoader.decodeSampled(data: data, maxDim: 2560)), 3000)
    }

    func testUndecodableBytesReturnNil() {
        XCTAssertNil(PageLoader.decodeSampled(data: Data("garbage".utf8), maxDim: 2560))
    }
}

final class CoverLoaderTests: XCTestCase {
    func testInvalidateDropsStaleCoverAndPageCount() async throws {
        let dir = try TestSupport.tempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Same.cbz")

        try TestSupport.zip(at: url, entries: [("1.png", TestSupport.png(width: 30, height: 40))])
        let first = await CoverLoader.load(for: url)
        XCTAssertEqual(first.pageCount, 1)
        XCTAssertNotNil(first.cover)

        // Replace the file with a different book at the same URL (what delete + re-import does).
        try FileManager.default.removeItem(at: url)
        try TestSupport.zip(at: url, entries: (1...4).map { ("\($0).png", TestSupport.png(width: 30, height: 40)) })

        let stale = await CoverLoader.load(for: url)
        XCTAssertEqual(stale.pageCount, 1, "cached until invalidated")

        CoverLoader.invalidate(url)
        let fresh = await CoverLoader.load(for: url)
        XCTAssertEqual(fresh.pageCount, 4)
    }
}
