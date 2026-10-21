import XCTest
import ChikaCore
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
