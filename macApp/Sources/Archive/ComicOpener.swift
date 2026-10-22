import Foundation
import ChikaCore

/// What the reader, covers and import validation need from a comic, whatever its container.
protocol ComicPages: AnyObject {
    var pageCount: Int { get }
    func readPage(_ index: Int) throws -> Data
}

extension CbzArchive: ComicPages {}

/// Opens any library comic for reading. Imported CBR/CB7 copies are already CBZ; one read in place
/// is converted once into the caches folder (keyed by file identity) and again only when it
/// changes. PDFs open with PDFKit. Blocking: call it off the main thread.
enum ComicOpener {
    static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Chika/Converted", isDirectory: true)

    static func open(_ url: URL) throws -> ComicPages {
        switch ComicFormatDetector.detect(head: leadingBytes(of: url), fileExtension: url.pathExtension) {
        case .pdf: return try PdfComic(url: url)
        case .cbr, .cb7: return try CbzArchive(url: converted(url))
        case .cbz, .unknown: return try CbzArchive(url: url)
        }
    }

    private static func converted(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let name = ReadingProgress.key(url).replacingOccurrences(of: "/", with: "_")
        let cached = cacheDir.appendingPathComponent(name).appendingPathExtension("cbz")
        let modified = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        if let done = modified(cached), let source = modified(url), done >= source { return cached }
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let partial = cached.appendingPathExtension(UUID().uuidString)
        defer { try? fm.removeItem(at: partial) }
        try CbrConverter.convertToCbz(source: url, destination: partial)
        // rename(2) replaces atomically, so a concurrent open never sees half a file.
        guard rename(partial.path, cached.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return cached
    }

    /// The first few bytes of `url` for magic-byte format detection. Empty (→ extension fallback)
    /// if the file can't be read.
    static func leadingBytes(of url: URL, count: Int = 8) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        return [UInt8]((try? handle.read(upToCount: count)) ?? Data())
    }
}
