import Foundation

/// Comics live as plain .cbz files in Documents/Comics. Importing a CBZ/ZIP copies it in; importing
/// a CBR/RAR converts it to CBZ first (see CbrConverter) so the reader only handles ZIP. The list
/// is a directory scan; per-comic resume lives in ReadingProgress.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var comics: [URL] = []
    @Published var importing = false
    @Published var importError: String?

    private let dir: URL

    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        comics = files
            .filter { $0.pathExtension.lowercased() == "cbz" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func importComic(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "cbr" || ext == "rar" {
            let dest = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".cbz")
            importing = true
            Task {
                do {
                    try await CbrConverter.convertToCbz(source: url, destination: dest)
                } catch {
                    importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                }
                importing = false
                refresh()
            }
        } else {
            // CBZ/ZIP: the picker hands us an owned copy. Normalize to a .cbz name so the directory
            // scan in refresh() finds it — a picked .zip is the same ZIP container the reader reads.
            let dest = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".cbz")
            try? FileManager.default.removeItem(at: dest)
            do {
                do { try FileManager.default.moveItem(at: url, to: dest) }
                catch { try FileManager.default.copyItem(at: url, to: dest) }
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
