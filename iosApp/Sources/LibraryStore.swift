import Foundation

/// Comics live as plain .cbz files in Documents/Comics — no database yet. Import copies the picked
/// file in; the list is just a directory scan. (Resume state and covers come with the real
/// library port.)
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var comics: [URL] = []

    private let dir: URL

    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        comics = files
            .filter { ["cbz", "zip"].contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// Imports a picker-provided copy (UIDocumentPicker asCopy gives us a temp file we own).
    func importComic(from url: URL) {
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        refresh()
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }
}
