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
/// changes. PDFs open with PDFKit, a folder of images as its image files. Blocking: call it off the main thread.
enum ComicOpener {
    static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Chika/Converted", isDirectory: true)
    private static let conversionsLock = NSLock()
    private static var conversions: [String: NSLock] = [:]

    static func open(_ url: URL) throws -> ComicPages {
        // A folder has no leading bytes to detect: it is a folder of images.
        if isFolder(url) { return try FolderComic(url: url) }
        switch format(url) {
        case .pdf: return try PdfComic(url: url)
        case .cbr, .cb7: return try CbzArchive(url: converted(url))
        case .cbz, .unknown: return try CbzArchive(url: url)
        }
    }

    /// A comic's ComicInfo.xml, nil when it has none. A CBR/CB7 not converted yet has only that entry
    /// read, never the whole archive. Throws when the comic can't be read (yet: it may still be copying in).
    static func comicInfo(_ url: URL) throws -> ComicInfo? {
        if isFolder(url) { return nil }
        switch format(url) {
        case .pdf: return nil
        case .cbr, .cb7:
            if let cached = cachedConversion(url) { return try CbzArchive(url: cached).comicInfo }
            return try extracting(url, keep: ComicInfo.isEntry) { $0.first.flatMap { ComicInfo.parse($0.data) } }
        case .cbz, .unknown: return try CbzArchive(url: url).comicInfo
        }
    }

    /// A comic's first page and page count, for its library card. A CBR/CB7 not converted yet has only
    /// its first page extracted.
    static func firstPage(_ url: URL, cancelled: () -> Bool = { false }) throws -> (page: Data?, count: Int) {
        if !isFolder(url), [.cbr, .cb7].contains(format(url)), cachedConversion(url) == nil {
            var names: [String] = []
            _ = try CbrReader.extract(at: url, into: FileManager.default.temporaryDirectory) { name in
                if isImageEntry(name) { names.append(name) }
                return false   // only listing
            }
            guard let first = names.min(by: NaturalOrder.isOrderedBefore), !cancelled() else { return (nil, names.count) }
            return (try extracting(url, keep: { $0 == first }) { $0.first?.data }, names.count)
        }
        let comic = try open(url)
        guard comic.pageCount > 0, !cancelled() else { return (nil, comic.pageCount) }
        return (try comic.readPage(0), comic.pageCount)
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func format(_ url: URL) -> ComicFormat {
        ComicFormatDetector.detect(head: leadingBytes(of: url), fileExtension: url.pathExtension)
    }

    /// The entries of a CBR/CB7 that pass `keep`, read into a scratch folder that is gone afterwards.
    private static func extracting<T>(_ url: URL, keep: (String) -> Bool, _ use: ([(name: String, data: Data)]) throws -> T) throws -> T {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("entries-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        return try use(try CbrReader.extract(at: url, into: scratch, keep: keep).map { ($0.name, try Data(contentsOf: $0.file)) })
    }

    private static func cachedFile(_ url: URL) -> URL {
        cacheDir.appendingPathComponent(ReadingProgress.key(url).replacingOccurrences(of: "/", with: "_")).appendingPathExtension("cbz")
    }

    /// The cached CBZ of a CBR/CB7 when it is at least as new as the archive.
    private static func cachedConversion(_ url: URL) -> URL? {
        let cached = cachedFile(url)
        let modified = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        guard let done = modified(cached), let source = modified(url), done >= source else { return nil }
        return cached
    }

    private static func converted(_ url: URL) throws -> URL {
        // One conversion per comic at a time: the reader, the pre-detector and an export opening the same
        // archive wait for the first and then share its result instead of each converting it again.
        let cached = cachedFile(url)
        let lock = conversionsLock.withLock {
            if let lock = conversions[cached.path] { return lock }
            let lock = NSLock()
            conversions[cached.path] = lock
            return lock
        }
        lock.lock()
        defer { lock.unlock() }
        if let done = cachedConversion(url) { return done }
        let fm = FileManager.default
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
