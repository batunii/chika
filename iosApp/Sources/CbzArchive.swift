import Foundation
import ZIPFoundation
import ChikaShared

/// iOS CBZ implementation of the comic-archive contract. Entry filtering (isImageEntry) and page
/// ordering (NaturalOrderComparator) come from the shared Kotlin core so iOS and Android agree on
/// what counts as a page and in which order pages are read.
final class CbzArchive {
    private let archive: Archive
    private let entries: [Entry]

    init(url: URL) throws {
        archive = try Archive(url: url, accessMode: .read)
        entries = archive
            .filter { $0.type == .file && ComicArchiveKt.isImageEntry(name: $0.path) }
            .sorted { NaturalOrderComparator.shared.compare(a: $0.path, b: $1.path) < 0 }
    }

    var pageCount: Int { entries.count }

    func pageName(_ index: Int) -> String { entries[index].path }

    func readPage(_ index: Int) throws -> Data {
        var data = Data()
        _ = try archive.extract(entries[index], skipCRC32: true) { data.append($0) }
        return data
    }
}
