import Foundation
import ZIPFoundation
import ChikaShared

/// iOS CBZ implementation of the comic-archive contract. Page selection and ordering come from the
/// shared Kotlin `ComicPages` so iOS and Android agree on what counts as a page and in which order
/// pages are read.
final class CbzArchive {
    enum PageError: LocalizedError {
        case tooLarge(Int)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let n): return "Page \(n + 1) is too large to open"
            }
        }
    }

    private let archive: Archive
    private let entries: [Entry]
    private let maxPageBytes: Int

    init(url: URL, maxPageBytes: Int = Int(PageConstants.shared.maxPageBytes)) throws {
        self.maxPageBytes = maxPageBytes
        archive = try Archive(url: url, accessMode: .read)
        let files = archive.filter { $0.type == .file }
        let order = ComicPages.shared.orderedImageIndices(names: files.map { $0.path })
        entries = order.map { files[$0.intValue] }
    }

    var pageCount: Int { entries.count }

    /// Reads one page, refusing entries larger than [maxPageBytes] (a corrupt or hostile archive must
    /// fail the page, not exhaust memory). The declared size can lie, so the read itself is bounded too.
    func readPage(_ index: Int) throws -> Data {
        let entry = entries[index]
        if entry.uncompressedSize > UInt64(maxPageBytes) { throw PageError.tooLarge(index) }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { chunk in
            data.append(chunk)
            if data.count > maxPageBytes { throw PageError.tooLarge(index) }
        }
        return data
    }
}
