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
    #if targetEnvironment(macCatalyst)
    private var activeMacImports = 0
    #endif

    /// Types the file importer allows. Includes the app's exported CBZ/CBR types plus the generic
    /// zip/archive/rar families so a plain .zip or .rar comic is selectable too.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.zip, .archive]
        if let cbz = UTType("com.chakra.comicreader.cbz") { types.append(cbz) }
        if let cbr = UTType("com.chakra.comicreader.cbr") { types.append(cbr) }
        if let rar = UTType("com.rarlab.rar-archive") { types.append(rar) }
        #if targetEnvironment(macCatalyst)
        // macOS may associate these extensions with types declared by another installed reader.
        for ext in ["cbz", "cbr", "rar"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        // Catalyst's native picker can reject its own custom archive types. The Mac fallback
        // permits file selection; importMacComic validates the archive before adding it.
        types.append(.data)
        #endif
        return types
    }

    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

    func importComic(from url: URL) {
        #if targetEnvironment(macCatalyst)
        importMacComic(from: url)
        #else
        // .fileImporter hands back security-scoped URLs (NOT owned copies). Open the scope, copy
        // synchronously into our sandbox, then relinquish it. Never move — we don't own the source.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let baseName = url.deletingPathExtension().lastPathComponent
        let dest = dir.appendingPathComponent(baseName + ".cbz")

        // Route by magic bytes (extension is only the fallback), matching Android's
        // ComicArchiveFactory exactly — so a mislabeled ".cbz" that is really a RAR is converted,
        // not copied in broken. Detection logic itself lives in the shared ComicFormatDetector.
        let format = ComicFormatDetector.shared.detect(head: Self.leadingBytes(of: url), fileExtension: ext)

        if format == .cbr {
            // Stage a local copy first so conversion isn't reading a scoped URL on a background Task.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            do {
                try FileManager.default.copyItem(at: url, to: staged)
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
            importing = true
            Task {
                defer { try? FileManager.default.removeItem(at: staged) }
                do {
                    try await CbrConverter.convertToCbz(source: staged, destination: dest)
                    ReadingProgress.markOpened(dest)   // fresh import sorts to the top
                } catch { importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
                importing = false
                refresh()
            }
        } else {
            // CBZ/ZIP: copy the same container in under a .cbz name so refresh()'s scan finds it.
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                ReadingProgress.markOpened(dest)   // fresh import sorts to the top
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
            refresh()
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private enum MacImportError: LocalizedError {
        case unsupported, noImages
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Choose a CBZ, CBR, ZIP, or RAR comic archive."
            case .noImages: return "No image pages found in this archive."
            }
        }
    }

    /// Stage and validate off the main thread. A failed import must not erase an existing comic.
    private func importMacComic(from url: URL) {
        activeMacImports += 1
        importing = true
        let destination = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".cbz")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: staging) }
                    let source = staging.appendingPathComponent("source").appendingPathExtension(url.pathExtension)
                    var coordinationError: NSError?
                    var copyError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readableURL in
                        do { try fm.copyItem(at: readableURL, to: source) }
                        catch { copyError = error }
                    }
                    if let error = coordinationError ?? copyError { throw error }
                    let format = ComicFormatDetector.shared.detect(head: Self.leadingBytes(of: source), fileExtension: url.pathExtension)
                    let ready = staging.appendingPathComponent("ready.cbz")
                    if format == .cbr {
                        try await CbrConverter.convertToCbz(source: source, destination: ready)
                    } else if format == .cbz {
                        try fm.moveItem(at: source, to: ready)
                    } else {
                        throw MacImportError.unsupported
                    }
                    guard try CbzArchive(url: ready).pageCount > 0 else { throw MacImportError.noImages }
                    if fm.fileExists(atPath: destination.path) {
                        _ = try fm.replaceItemAt(destination, withItemAt: ready)
                    } else {
                        try fm.moveItem(at: ready, to: destination)
                    }
                }.value
                ReadingProgress.markOpened(destination)
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
            activeMacImports -= 1
            importing = activeMacImports > 0
            refresh()
        }
    }
    #endif

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        ReadingProgress.clear(url)
        refresh()
    }

    /// The first few bytes of [url] as a Kotlin byte array, for shared magic-byte format detection.
    /// Returns empty (→ extension fallback) if the file can't be read.
    nonisolated private static func leadingBytes(of url: URL, count: Int = 8) -> KotlinByteArray {
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
