import Foundation
import UniformTypeIdentifiers
import ChikaCore

/// Comics live as plain .cbz files in the container's Documents/Comics, the folder the Catalyst
/// app used (same bundle id, same container), so an existing library carries over. Every import, whatever its
/// format, goes through one path: stage a copy, convert CBR → CBZ, validate, then move in under a
/// name that never overwrites. The list is a directory scan; per-comic resume lives in ReadingProgress.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var comics: [URL] = []
    @Published var importing = false
    @Published var importError: String?

    private let dir: URL
    private var activeImports = 0

    /// Types the file importer allows. Includes the app's exported CBZ/CBR types plus the generic
    /// zip/archive/rar families so a plain .zip or .rar comic is selectable too.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.zip, .archive]
        if let cbz = UTType("com.chakra.comicreader.cbz") { types.append(cbz) }
        if let cbr = UTType("com.chakra.comicreader.cbr") { types.append(cbr) }
        if let rar = UTType("com.rarlab.rar-archive") { types.append(rar) }
        // macOS may associate these extensions with types declared by another installed reader.
        for ext in ["cbz", "cbr", "rar"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// `directory` overrides the library folder (tests pass a temp dir).
    init(directory: URL? = nil) {
        dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ReadingProgress.migrateLegacy(in: dir)
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let opened = ReadingProgress.openedMap()
        comics = files
            .filter { ["cbz", "zip"].contains($0.pathExtension.lowercased()) }
            .map { ($0, opened[ReadingProgress.key($0)] ?? 0) }
            // Most-recently-opened first (Android's `ORDER BY lastOpened DESC`), then natural filename.
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending
            }
            .map(\.0)
    }

    /// Imports off the main thread. The returned task lets tests await completion; the UI ignores it.
    @discardableResult
    func importComic(from url: URL) -> Task<Void, Never> {
        activeImports += 1
        importing = true
        let dir = dir
        return Task {
            do {
                let dest = try await Task.detached(priority: .userInitiated) { try Self.install(url, into: dir) }.value
                ReadingProgress.markOpened(dest)   // fresh import sorts to the top
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
            activeImports -= 1
            importing = activeImports > 0
            refresh()
        }
    }

    func delete(_ url: URL) {
        ReadingProgress.clear(url)   // first: its key is read from the file
        try? FileManager.default.removeItem(at: url)
        CoverLoader.evict(url)
        refresh()
    }

    private enum ImportError: LocalizedError {
        case unsupported, noImages
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Choose a CBZ, CBR, ZIP, or RAR comic archive."
            case .noImages: return "No image pages found in this archive."
            }
        }
    }

    /// Stage, convert and validate, then move into `dir`. A failed import leaves the library untouched.
    nonisolated private static func install(_ url: URL, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // On the library's volume, so the final rename below is atomic.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dir, create: true)
        defer { try? fm.removeItem(at: staging) }
        let source = staging.appendingPathComponent("source").appendingPathExtension(url.pathExtension)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readableURL in
            do { try fm.copyItem(at: readableURL, to: source) }
            catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }

        // Route by magic bytes (extension is only the fallback), matching Android's
        // ComicArchiveFactory, so a mislabeled ".cbz" that is really a RAR is converted.
        let ready = staging.appendingPathComponent("ready.cbz")
        switch ComicFormatDetector.detect(head: leadingBytes(of: source), fileExtension: url.pathExtension) {
        case .cbr: try CbrConverter.convertToCbz(source: source, destination: ready)
        case .cbz: try fm.moveItem(at: source, to: ready)
        case .unknown: throw ImportError.unsupported
        }
        guard try CbzArchive(url: ready).pageCount > 0 else { throw ImportError.noImages }

        let base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let dest = dir.appendingPathComponent(n == 1 ? "\(base).cbz" : "\(base) \(n).cbz")
            // RENAME_EXCL fails instead of replacing, so even two concurrent imports never clobber.
            if renamex_np(ready.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return dest }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            n += 1
        }
    }

    /// The first few bytes of `url` for magic-byte format detection. Empty (→ extension fallback)
    /// if the file can't be read.
    nonisolated private static func leadingBytes(of url: URL, count: Int = 8) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        return [UInt8]((try? handle.read(upToCount: count)) ?? Data())
    }
}
