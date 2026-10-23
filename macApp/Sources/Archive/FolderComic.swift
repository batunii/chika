import Foundation
import ChikaCore

/// A folder of page images read in place as one comic: its own image files (not its subfolders') in
/// natural order.
// shortcut: stored detections key on the folder's own size and date, which change when pages are added
// or removed but not when one is overwritten in place; fold the pages' dates into the revision if that bites.
final class FolderComic: ComicPages {
    private let pages: [URL]

    init(url: URL) throws { pages = try Self.pages(in: url) }

    var pageCount: Int { pages.count }

    func readPage(_ index: Int) throws -> Data { try Data(contentsOf: pages[index]) }

    static func pages(in folder: URL) throws -> [URL] {
        ImageFolder.pages(try entries(folder).filter(\.isFile).map(\.name)).map { folder.appendingPathComponent($0) }
    }

    /// Whether `folder` holds only images (hidden files aside), so it is one comic rather than a folder of them.
    /// A subfolder or link is never a page, whatever its name.
    static func isComic(_ folder: URL) -> Bool {
        guard let entries = try? entries(folder),
              !entries.contains(where: { !$0.isFile && !$0.name.hasPrefix(".") }) else { return false }
        return ImageFolder.isComic(entries.map(\.name))
    }

    /// The folder's entries and whether each is a regular file: a folder named "02.jpg" would be copied
    /// whole on import, and a link imports as a link entry the archive reader drops.
    private static func entries(_ folder: URL) throws -> [(name: String, isFile: Bool)] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]).map {
            ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true)
        }
    }
}
