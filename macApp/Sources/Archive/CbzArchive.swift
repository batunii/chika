import Foundation
import ZIPFoundation
import ChikaCore

/// CBZ implementation of the comic-archive contract. Entry filtering (isImageEntry) and page
/// ordering (NaturalOrder) come from ChikaCore so the Mac and Android agree on what counts as a
/// page and in which order pages are read.
final class CbzArchive {
    private let archive: Archive
    private let entries: [Entry]

    init(url: URL) throws {
        archive = try Archive(url: url, accessMode: .read)
        entries = archive
            .filter { $0.type == .file && isImageEntry($0.path) }
            .sorted { NaturalOrder.isOrderedBefore($0.path, $1.path) }
    }

    var pageCount: Int { entries.count }

    /// The archive's ComicInfo.xml, if it has a readable one.
    var comicInfo: ComicInfo? {
        guard let entry = archive.first(where: { $0.type == .file && ComicInfo.isEntry($0.path) }) else { return nil }
        var data = Data()
        guard (try? archive.extract(entry, skipCRC32: true) { data.append($0) }) != nil else { return nil }
        return ComicInfo.parse(data)
    }

    func readPage(_ index: Int) throws -> Data {
        var data = Data()
        _ = try archive.extract(entries[index], skipCRC32: true) { data.append($0) }
        return data
    }
}
