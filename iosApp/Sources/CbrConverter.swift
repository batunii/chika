import Foundation
import SwiftArchive
import ZIPFoundation
import ChikaShared

/// Converts an imported CBR/RAR archive to CBZ once, on import, so the reader only ever handles
/// plain ZIP. Reading RAR uses libarchive's BSD-licensed RAR5 reader (via SwiftArchive); image
/// filtering and page ordering reuse the shared Kotlin core, identical to the CBZ path.
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
        let reader = try await ArchiveReader(reading: .fileURL(source))
        let entries = try await reader.readAll()
            .filter { $0.entry.fileType == .regular && ComicArchiveKt.isImageEntry(name: $0.entry.path) }
            .sorted { NaturalOrderComparator.shared.compare(a: $0.entry.path, b: $1.entry.path) < 0 }
        guard !entries.isEmpty else { throw ConversionError.noImages }

        // Stage the images in a temp directory with zero-padded, order-preserving names, then zip
        // the directory into the destination CBZ.
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("cbr-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for (index, item) in entries.enumerated() {
            let ext = (item.entry.path as NSString).pathExtension
            let name = String(format: "%05d.%@", index, ext.isEmpty ? "jpg" : ext)
            try Data(item.bytes).write(to: staging.appendingPathComponent(name))
        }

        try? fm.removeItem(at: destination)
        try fm.zipItem(at: staging, to: destination, shouldKeepParent: false)
    }
}
