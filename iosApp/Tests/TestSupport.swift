import UIKit
import ZIPFoundation

/// Helpers that build real (tiny) comic archives for the unit tests.
enum TestSupport {
    /// A decodable PNG of the given pixel size (scale 1, so pixels == points).
    static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Writes a ZIP at [url] with the given (entry name, bytes) entries, stored uncompressed.
    static func zip(at url: URL, entries: [(String, Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in entries {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .none) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    /// A fresh empty temp directory, removed by the caller's `addTeardownBlock`.
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chika-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
