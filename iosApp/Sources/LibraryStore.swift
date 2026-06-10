import Foundation
import UniformTypeIdentifiers

/// Comics live as plain .cbz files in Documents/Comics. Importing a CBZ/ZIP copies it in; importing
/// a CBR/RAR converts it to CBZ first (see CbrConverter) so the reader only handles ZIP. The list
/// is a directory scan; per-comic resume lives in ReadingProgress.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var comics: [URL] = []
    @Published var importing = false
    @Published var importError: String?

    private let dir: URL

    /// Types the file importer allows. Includes the app's exported CBZ/CBR types plus the generic
    /// zip/archive/rar families so a plain .zip or .rar comic is selectable too.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.zip, .archive]
        if let cbz = UTType("com.chakra.comicreader.cbz") { types.append(cbz) }
        if let cbr = UTType("com.chakra.comicreader.cbr") { types.append(cbr) }
        if let rar = UTType("com.rarlab.rar-archive") { types.append(rar) }
        return types
    }

    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
    }

    /// Raw view of what's actually on disk, for the on-screen diagnostic.
    var storageReport: String {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let names = all.map { $0.lastPathComponent }.sorted()
        return "dir: \(dir.path)\nfiles (\(names.count)): \(names.isEmpty ? "—" : names.joined(separator: ", "))"
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        comics = files
            .filter { ["cbz", "zip"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func importComic(from url: URL) {
        // .fileImporter hands back security-scoped URLs (NOT owned copies). Open the scope, copy
        // synchronously into our sandbox, then relinquish it. Never move — we don't own the source.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let baseName = url.deletingPathExtension().lastPathComponent
        let dest = dir.appendingPathComponent(baseName + ".cbz")

        if ext == "cbr" || ext == "rar" {
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
                do { try await CbrConverter.convertToCbz(source: staged, destination: dest) }
                catch { importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
                importing = false
                refresh()
            }
        } else {
            // CBZ/ZIP: copy the same container in under a .cbz name so refresh()'s scan finds it.
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
            refresh()
        }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        ReadingProgress.clear(url)
        refresh()
    }
}
