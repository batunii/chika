import QuickLookThumbnailing
import ImageIO
import ChikaCore

/// Finder thumbnails for comics: the first page in reading order, the same page the library shows
/// as the cover. Reuses the app's archive readers; no conversion, nothing cached.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let file = try FileHandle(forReadingFrom: request.fileURL)
            defer { try? file.close() }
            let head = try file.read(upToCount: 8) ?? Data()
            let data: Data
            switch ComicFormatDetector.detect(head: Array(head), fileExtension: request.fileURL.pathExtension) {
            case .cbz:
                let archive = try CbzArchive(url: request.fileURL)
                guard archive.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
                data = try archive.readPage(0)
            case .cbr, .cb7:
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                var names: [String] = []
                // Scan names before extracting so only the naturally first page is written.
                _ = try CbrReader.extract(at: request.fileURL, into: dir) {
                    if isImageEntry($0) { names.append($0) }
                    return false
                }
                guard let first = names.min(by: NaturalOrder.isOrderedBefore) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let pages = try CbrReader.extract(at: request.fileURL, into: dir, keep: { $0 == first })
                guard let page = pages.first else { throw CocoaError(.fileReadCorruptFile) }
                data = try Data(contentsOf: page.file)
            case .pdf, .unknown:   // Finder already draws PDF thumbnails
                throw CocoaError(.fileReadUnknown)
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(request.maximumSize.width, request.maximumSize.height) * request.scale,
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let fit = min(request.maximumSize.width / CGFloat(image.width),
                          request.maximumSize.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
            handler(QLThumbnailReply(contextSize: size, drawing: { context in
                context.draw(image, in: CGRect(origin: .zero, size: size))
                return true
            }), nil)
        } catch {
            handler(nil, error)
        }
    }
}
