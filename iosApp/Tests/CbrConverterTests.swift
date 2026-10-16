import XCTest
import UIKit
import ZIPFoundation
@testable import Chika

/// libarchive reads ZIP as well as RAR, so a ZIP stands in for a CBR here: the streaming extraction,
/// filtering, natural ordering and CBZ repackaging are format-independent.
final class CbrConverterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestSupport.tempDir()
        let d = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
    }

    private func pageWidth(_ cbz: URL, _ index: Int) throws -> Int {
        let data = try CbzArchive(url: cbz).readPage(index)
        return Int(try XCTUnwrap(UIImage(data: data)).size.width)
    }

    func testConvertsToNaturallyOrderedCbzDroppingNonImages() async throws {
        // Widths identify each page: page "N" is N*10 px wide. Archive order is deliberately scrambled.
        let source = dir.appendingPathComponent("in.cbr")
        try TestSupport.zip(at: source, entries: [
            ("10.png", TestSupport.png(width: 100, height: 50)),
            ("notes.txt", Data("not a page".utf8)),
            ("2.png", TestSupport.png(width: 20, height: 50)),
            ("1.png", TestSupport.png(width: 10, height: 50)),
        ])
        let dest = dir.appendingPathComponent("out.cbz")

        try await CbrConverter.convertToCbz(source: source, destination: dest)

        let cbz = try CbzArchive(url: dest)
        XCTAssertEqual(cbz.pageCount, 3, "notes.txt is not a page")
        XCTAssertEqual([try pageWidth(dest, 0), try pageWidth(dest, 1), try pageWidth(dest, 2)], [10, 20, 100])
    }

    func testArchiveWithNoImagesFailsAndLeavesNoDestination() async throws {
        let source = dir.appendingPathComponent("text.cbr")
        try TestSupport.zip(at: source, entries: [("readme.txt", Data("hi".utf8))])
        let dest = dir.appendingPathComponent("out.cbz")

        do {
            try await CbrConverter.convertToCbz(source: source, destination: dest)
            XCTFail("expected noImages")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        }
    }

    func testExtractEntriesStreamsEachEntryToItsOwnFile() throws {
        let source = dir.appendingPathComponent("in.zip")
        let big = Data(repeating: 7, count: 300_000)   // larger than the 64 KB read chunk
        try TestSupport.zip(at: source, entries: [("a.jpg", big), ("b.txt", Data("x".utf8))])
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let extracted = try CbrReader.extractEntries(at: source, include: { $0.hasSuffix(".jpg") }, into: out)

        XCTAssertEqual(extracted.map(\.path), ["a.jpg"])
        XCTAssertEqual(try Data(contentsOf: extracted[0].file), big)
    }

    func testNonArchiveThrows() throws {
        let junk = dir.appendingPathComponent("junk.cbr")
        try Data("definitely not an archive".utf8).write(to: junk)
        XCTAssertThrowsError(try CbrReader.extractEntries(at: junk, include: { _ in true }, into: dir))
    }
}
