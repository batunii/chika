import AppKit
import ImageIO
import os

/// Loads and caches comic cover thumbnails (page 0 of each CBZ). Uses ImageIO downsampling, which
/// decodes JPEG/PNG/HEIC/WebP robustly and builds a small thumbnail without inflating the full-res
/// page into memory.
enum CoverLoader {
    private static let cache = NSCache<NSURL, NSImage>()
    private static let countCache = NSCache<NSURL, NSNumber>()
    // A few at a time off the cooperative pool: a long library starts many cards at once, and each
    // load blocks on the archive.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Loads a comic's cover thumbnail (page 0) AND its page count in a single archive open, both
    /// cached. Page count feeds the library's "N pages" label for unread comics (Android parity).
    /// A card scrolled away (its task cancelled) stops before the open and before the decode.
    static func load(for url: URL) async -> (cover: NSImage?, pageCount: Int) {
        let cachedCover = cache.object(forKey: url as NSURL)
        let cachedCount = countCache.object(forKey: url as NSURL)?.intValue
        if let cachedCover, let cachedCount { return (cachedCover, cachedCount) }

        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let isCancelled = { cancelled.withLock { $0 } }
        let result: (NSImage?, Int)? = await withTaskCancellationHandler {
            await withCheckedContinuation { done in
                queue.addOperation {
                    // Nil when cancelled or unreadable (a comic still being copied in): nothing is cached.
                    guard !isCancelled(), let first = try? ComicOpener.firstPage(url, cancelled: isCancelled), !isCancelled() else {
                        return done.resume(returning: nil)
                    }
                    done.resume(returning: (first.page.flatMap { thumbnail(from: $0, maxPixel: 600) ?? NSImage(data: $0) }, first.count))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        guard let result else { return (nil, 0) }
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
