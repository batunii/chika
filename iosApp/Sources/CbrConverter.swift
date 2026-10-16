import Foundation
import ZIPFoundation
import ChikaShared

/// Converts an imported CBR/RAR archive to CBZ once, on import, so the reader only ever handles
/// plain ZIP. Reading uses libarchive's BSD-licensed RAR5 reader (CbrReader); image filtering and
/// page ordering reuse the shared Kotlin core, identical to the CBZ path.
enum CbrConverter {
    enum ConversionError: LocalizedError {
        case noImages
        var errorDescription: String? {
            switch self {
            case .noImages: return "No image pages found in this archive"
            }
        }
    }

    static func convertToCbz(source: URL, destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appendingPathComponent("cbr-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let tmpZip = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cbz")
            defer {
                try? fm.removeItem(at: staging)
                try? fm.removeItem(at: tmpZip)
            }

            // Stream image entries to disk (one entry in memory at a time), then order them.
            let all = try CbrReader.extractEntries(
                at: source,
                include: { ComicPagesKt.isImageEntry(name: $0) },
                into: staging
            )
            let order = ComicPages.shared.orderedImageIndices(names: all.map { $0.path })
            let extracted = order.map { all[$0.intValue] }
            guard !extracted.isEmpty else { throw ConversionError.noImages }

            // Rename to zero-padded, order-preserving names, then zip.
            let pages = staging.appendingPathComponent("pages", isDirectory: true)
            try fm.createDirectory(at: pages, withIntermediateDirectories: true)
            for (index, item) in extracted.enumerated() {
                let ext = (item.path as NSString).pathExtension
                let name = String(format: "%05d.%@", index, ext.isEmpty ? "jpg" : ext)
                try fm.moveItem(at: item.file, to: pages.appendingPathComponent(name))
            }

            // Zip to a temp file and move into place, so a failure never leaves a partial CBZ.
            try fm.zipItem(at: pages, to: tmpZip, shouldKeepParent: false)
            try fm.moveItem(at: tmpZip, to: destination)
        }.value
    }
}
