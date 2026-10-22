import AppKit
import ImageIO

/// Loads and caches comic cover thumbnails (page 0 of each CBZ). Uses ImageIO downsampling, which
/// decodes JPEG/PNG/HEIC/WebP robustly and builds a small thumbnail without inflating the full-res
/// page into memory.
enum CoverLoader {
    private static let cache = NSCache<NSURL, NSImage>()
    private static let countCache = NSCache<NSURL, NSNumber>()

    /// Loads a comic's cover thumbnail (page 0) AND its page count in a single archive open, both
    /// cached. Page count feeds the library's "N pages" label for unread comics (Android parity).
    static func load(for url: URL) async -> (cover: NSImage?, pageCount: Int) {
        let cachedCover = cache.object(forKey: url as NSURL)
        let cachedCount = countCache.object(forKey: url as NSURL)?.intValue
        if let cachedCover, let cachedCount { return (cachedCover, cachedCount) }

        let result: (NSImage?, Int) = await Task.detached(priority: .userInitiated) {
            guard let archive = try? ComicOpener.open(url) else { return (nil, 0) }
            let n = archive.pageCount
            guard n > 0, let data = try? archive.readPage(0) else { return (nil, n) }
            let img = thumbnail(from: data, maxPixel: 600) ?? NSImage(data: data)
            return (img, n)
        }.value

        if let img = result.0 { cache.setObject(img, forKey: url as NSURL) }
        countCache.setObject(NSNumber(value: result.1), forKey: url as NSURL)
        return result
    }

    /// Drops a removed comic's cover so a later import under the same name doesn't show the old one.
    static func evict(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        countCache.removeObject(forKey: url as NSURL)
    }

    private static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: .zero)
    }
}
