import Foundation
import ZIPFoundation
import ChikaCore

/// Converts a CBR/RAR or CB7/7z archive to CBZ once (on import, or into the cache when read in
/// place), so the reader only ever handles plain ZIP. libarchive reads both formats. Reading uses libarchive's BSD-licensed RAR5 reader (CbrReader); image filtering and
/// page ordering reuse ChikaCore, identical to the CBZ path. Blocking: call it off the main thread.
enum CbrConverter {
    enum ConversionError: LocalizedError {
        case noImages
        var errorDescription: String? {
            switch self {
            case .noImages: return "No image pages found in this archive"
            }
        }
    }

    static func convertToCbz(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("cbr-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var entries = try CbrReader.extract(at: source, into: staging) { isImageEntry($0) || ComicInfo.isEntry($0) }
            .sorted { NaturalOrder.isOrderedBefore($0.name, $1.name) }
        // Carry ComicInfo.xml over (at the root, where readers look) so series metadata survives.
        if let info = entries.firstIndex(where: { ComicInfo.isEntry($0.name) }) {
            try fm.moveItem(at: entries.remove(at: info).file, to: staging.appendingPathComponent("ComicInfo.xml"))
        }
        guard !entries.isEmpty else { throw ConversionError.noImages }

        // Rename in place to zero-padded, order-preserving names (extracted files are bare indices,
        // so they never collide with these), then zip. Pages are already compressed: store them.
        for (index, item) in entries.enumerated() {
            let ext = (item.name as NSString).pathExtension
            let name = String(format: "%05d.%@", index, ext.isEmpty ? "jpg" : ext)
            try fm.moveItem(at: item.file, to: staging.appendingPathComponent(name))
        }
        try fm.zipItem(at: staging, to: destination, shouldKeepParent: false, compressionMethod: .none)
    }
}
