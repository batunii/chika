import Foundation
import PDFKit
import UniformTypeIdentifiers
import ChikaCore

/// A PDF comic. Each page renders at the reader's page size and is handed over as JPEG data, so
/// covers, the page cache and panel detection treat it exactly like an archive page.
// shortcut: render → JPEG → decode costs one re-encode per page; render straight to a CGImage in
// PageLoader if big PDFs feel slow.
final class PdfComic: ComicPages {
    private let document: PDFDocument

    init(url: URL) throws {
        guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        self.document = document
    }

    var pageCount: Int { document.pageCount }

    func readPage(_ index: Int) throws -> Data {
        guard let page = document.page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
        let box = page.bounds(for: .mediaBox)
        let scale = CGFloat(PageConstants.maxPageDimension) / max(box.width, box.height, 1)
        let image = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
        let data = NSMutableData()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
