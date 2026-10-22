import AppKit
import CryptoKit
import ChikaCore

/// Export Panel Corrections… (File menu): every page whose panels were corrected by hand, written as
/// a YOLO training pair in the dataset layout of training/scripts, so the reader's fixes can teach the
/// panel detector. Panel boxes only (class 0), like the COMICS pages: no text boxes.
enum TrainingExport {
    /// Asks for a folder, exports into it off the main thread, then says how it went.
    @MainActor
    static func run(library: LibraryStore) {
        let overrides = ReadingProgress.allPanelOverrides()
        guard !overrides.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No panel corrections yet"
            alert.informativeText = "Fix a page's panels with Edit Panels (⌘E) in the reader, then export them."
            alert.runModal()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the training images and labels."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let comics = Dictionary(library.keys.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try Self.export(overrides, comics: comics, to: folder) }.value
                let count = { (n: Int, noun: String) in "\(n) \(noun)\(n == 1 ? "" : "s")" }
                let alert = NSAlert()
                alert.messageText = "Exported \(count(result.pages, "page"))"
                alert.informativeText = "Images and labels are in images/train and labels/train of \(folder.lastPathComponent)."
                    + (result.missing == 0 ? "" : " Skipped \(count(result.missing, "edited page")) whose comic is no longer in the library.")
                    + (result.undrawn == 0 ? "" : " Skipped \(count(result.undrawn, "edited page")) with boxes not drawn by hand: only a page whose every box you drew in the panel editor is exported.")
                    + (result.failed == 0 ? "" : " Could not read \(count(result.failed, "edited page")): the comic will not open, or has changed since the edit.")
                alert.runModal()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Writes images/train/chika_<title>_p<page>.jpg and labels/train/<same>.txt under `folder` for each
    /// override whose comic is in `comics` (progress key → file) and whose boxes were all drawn by hand.
    /// `overrides` comes grouped by comic, as allPanelOverrides returns it. Returns the pages written, the
    /// overrides skipped because their comic left the library, those whose page could not be read or
    /// converted, and those with a box not drawn by hand.
    static func export(_ overrides: [(id: String, page: Int, panels: [Panel], drawn: Bool)], comics: [String: URL],
                       to folder: URL) throws -> (pages: Int, missing: Int, failed: Int, undrawn: Int) {
        let images = folder.appendingPathComponent("images/train", isDirectory: true)
        let labels = folder.appendingPathComponent("labels/train", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: labels, withIntermediateDirectories: true)
        func safeTitle(_ url: URL) -> String {
            var safe = String(url.deletingPathExtension().lastPathComponent.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
            // A title that fits the 255-byte name limit may not once chika_, <id>, _p<page> and .jpg are added.
            while safe.utf8.count > 200 { safe.removeLast() }
            return safe
        }
        // Comics whose titles would share a file name (APFS ignores case) also get 8 hex digits of their key.
        let titles = Set(overrides.map(\.id)).compactMap { comics[$0].map { safeTitle($0).lowercased() } }
        let clashing = Dictionary(grouping: titles, by: { $0 }).filter { $1.count > 1 }.keys
        var pages = 0, missing = 0, failed = 0, undrawn = 0
        var current: (id: String, stem: String, archive: ComicPages?)?
        for row in overrides {
            guard let url = comics[row.id] else { missing += 1; continue }
            // Boxes the editor started from are the reader's zoom regions (padded 5.7% a side, neighbours merged,
            // broad panels split), and merged or split boxes are rarely one panel: as labels they would teach the
            // detector to pad, merge and split. Only a page drawn box by box is a true panel layout.
            guard row.drawn else { undrawn += 1; continue }
            if current?.id != row.id {
                let safe = safeTitle(url)
                let id = SHA256.hash(data: Data(row.id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
                current = (row.id, "chika_" + safe + (clashing.contains(safe.lowercased()) ? "_" + id : ""), try? ComicOpener.open(url))
            }
            // [.fullPage] (saved with no boxes) goes out as one page-sized panel, the way the reader shows it.
            let lines = row.panels.compactMap(\.yoloLabel)
            guard !lines.isEmpty else { continue }   // degenerate boxes only
            // The range check: the file may have shrunk since the edit, and readPage traps past the end.
            guard let comic = current, let archive = comic.archive, (0..<archive.pageCount).contains(row.page),
                  let data = try? archive.readPage(row.page), let jpeg = jpeg(data) else { failed += 1; continue }
            let name = comic.stem + String(format: "_p%03d", row.page + 1)
            try jpeg.write(to: images.appendingPathComponent(name + ".jpg"), options: .atomic)
            try (lines.joined(separator: "\n") + "\n").write(to: labels.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            pages += 1
        }
        return (pages, missing, failed, undrawn)
    }

    /// The archive's own bytes when they already are JPEG, else the page decoded as the reader shows it
    /// (orientation applied, so the boxes still fit) and re-encoded.
    private static func jpeg(_ data: Data) -> Data? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return data }
        guard let image = PageLoader.decodeSampled(data: data, maxDim: PageConstants.maxPageDimension) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }
}
