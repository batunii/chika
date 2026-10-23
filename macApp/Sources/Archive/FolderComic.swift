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
        ImageFolder.pages(try FileManager.default.contentsOfDirectory(atPath: folder.path)).map { folder.appendingPathComponent($0) }
    }

    /// Whether `folder` holds only images (hidden files aside), so it is one comic rather than a folder of them.
    static func isComic(_ folder: URL) -> Bool {
        ImageFolder.isComic((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }
}
