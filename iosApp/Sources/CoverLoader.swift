import UIKit
import ImageIO

/// Loads and caches comic cover thumbnails (page 0 of each CBZ). Uses ImageIO downsampling, which
/// decodes JPEG/PNG/HEIC/WebP robustly and builds a small thumbnail without inflating the full-res
/// page into memory — more reliable than UIImage(data:) + byPreparingThumbnail for big scans.
enum CoverLoader {
    private static let cache = NSCache<NSURL, UIImage>()

    static func cover(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let archive = try? CbzArchive(url: url), archive.pageCount > 0,
                  let data = try? archive.readPage(0) else { return nil }
            return thumbnail(from: data, maxPixel: 600) ?? UIImage(data: data)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    private static func thumbnail(from data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
