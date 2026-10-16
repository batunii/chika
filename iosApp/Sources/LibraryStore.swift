import Foundation
import UniformTypeIdentifiers
import ChikaShared

/// Comics live as plain .cbz files in Documents/Comics. Importing a CBZ/ZIP copies it in; importing
/// a CBR/RAR converts it to CBZ first (see CbrConverter) so the reader only handles ZIP. The list
/// is a directory scan; per-comic resume lives in ReadingProgress.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var comics: [URL] = []
    @Published var importing = false
    @Published var importError: String?

    private let dir: URL
    private var importTask: Task<Void, Never>?
    private var activeImports = 0

    /// Types the file importer allows. Includes the app's exported CBZ/CBR types plus the generic
    /// zip/archive/rar families so a plain .zip or .rar comic is selectable too.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.zip, .archive]
        if let cbz = UTType("com.chakra.comicreader.cbz") { types.append(cbz) }
        if let cbr = UTType("com.chakra.comicreader.cbr") { types.append(cbr) }
        if let rar = UTType("com.rarlab.rar-archive") { types.append(rar) }
        return types
    }

    /// [directory] overrides the library folder (tests use a temp dir); production uses Documents/Comics.
    init(directory: URL? = nil) {
        dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        comics = files
            .filter { ["cbz", "zip"].contains($0.pathExtension.lowercased()) }
            // Most-recently-opened first (Android's `ORDER BY lastOpened DESC`), then natural filename.
            .sorted {
                let ta = ReadingProgress.openedAt($0), tb = ReadingProgress.openedAt($1)
                if ta != tb { return ta > tb }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// Imports are queued and run one at a time: concurrent CBR conversions multiply peak memory,
    /// and the `importing` flag must stay true until the LAST one finishes.
    func importComic(from url: URL) {
        activeImports += 1
        importing = true
        let previous = importTask
        importTask = Task {
            await previous?.value
            await performImport(url)
            activeImports -= 1
            importing = activeImports > 0
            refresh()
        }
    }

    private func performImport(_ url: URL) async {
        // .fileImporter hands back security-scoped URLs (NOT owned copies). Keep the scope open for
        // the whole copy, then relinquish it. Never move — we don't own the source.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        // Never overwrite an existing comic: a same-named different book would silently replace it
        // (and inherit its progress/cover), and a failed copy would destroy the original.
        let dest = Self.uniqueDestination(in: dir, baseName: url.deletingPathExtension().lastPathComponent)

        // Route by magic bytes (extension is only the fallback), matching Android's
        // ComicArchiveFactory exactly — so a mislabeled ".cbz" that is really a RAR is converted,
        // not copied in broken. Detection logic itself lives in the shared ComicFormatDetector.
        let isCbr = ComicFormatDetector.shared.detect(head: Self.leadingBytes(of: url), fileExtension: ext) == .cbr

        do {
            // Copy/convert off the main thread (these can be hundreds of MB).
            try await Task.detached(priority: .userInitiated) {
                if isCbr {
                    // Stage a local copy first so conversion isn't reading a scoped URL.
                    let staged = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                    try FileManager.default.copyItem(at: url, to: staged)
                    defer { try? FileManager.default.removeItem(at: staged) }
                    try await CbrConverter.convertToCbz(source: staged, destination: dest)
                } else {
                    // Copy to a temp name and move into place, so a failed copy never leaves a
                    // partial .cbz that refresh() would list as a (broken) comic.
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("cbz")
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try FileManager.default.copyItem(at: url, to: tmp)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                }
            }.value
            ReadingProgress.markOpened(dest)   // fresh import sorts to the top
            CoverLoader.invalidate(dest)
        } catch {
            importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// `Name.cbz`, or `Name 2.cbz`, `Name 3.cbz`… — the first name not already in the library.
    private static func uniqueDestination(in dir: URL, baseName: String) -> URL {
        var candidate = dir.appendingPathComponent(baseName + ".cbz")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(baseName) \(n).cbz")
            n += 1
        }
        return candidate
    }

    /// Removes an "Open in" Inbox copy once its import has been queued behind earlier imports.
    func discardInboxCopy(_ url: URL) {
        let previous = importTask
        Task {
            await previous?.value
            try? FileManager.default.removeItem(at: url)
        }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        ReadingProgress.clear(url)
        CoverLoader.invalidate(url)
        refresh()
    }

    /// The first few bytes of [url] as a Kotlin byte array, for shared magic-byte format detection.
    /// Returns empty (→ extension fallback) if the file can't be read.
    private static func leadingBytes(of url: URL, count: Int = 8) -> KotlinByteArray {
        let data: Data = {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: count)) ?? Data()
        }()
        let bytes = KotlinByteArray(size: Int32(data.count))
        for (i, b) in data.enumerated() { bytes.set(index: Int32(i), value: Int8(bitPattern: b)) }
        return bytes
    }
}
