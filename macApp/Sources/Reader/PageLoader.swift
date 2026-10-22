import Foundation
import ImageIO
import ChikaCore

/// Decodes comic pages to CGImages, downsampling very large scans and keeping recently viewed pages
/// hot in an LRU cache so back/forward navigation is instant and memory stays bounded.
///
/// This deliberately mirrors Android's PageLoader byte-for-byte in the part that matters for
/// detection parity: the same long-edge limit (2560) and the same power-of-two sampling rule, so a
/// page is downsampled to the SAME dimensions on both platforms (and, like Android, typical
/// 2000–4000px manga is left at full resolution — sampling only kicks in above ~5120px). The
/// detector letterboxes from these dimensions, so matching them keeps detections identical across
/// platforms. One PageLoader is created per open comic.
final class PageLoader: @unchecked Sendable {   // thread-safe: NSCache is, and the archive read is locked
    private let archive: ComicPages
    private let maxDimension: Int
    private let cache = NSCache<NSNumber, CGImage>()
    // ZIPFoundation's Archive isn't thread-safe, so the read is serialized; the decode runs outside
    // the lock so a slow decode never stalls the other queue's read (a load/prefetch race may decode
    // one page twice, which is harmless).
    private let lock = NSLock()

    static let defaultMaxDimension = PageConstants.maxPageDimension

    init(archive: ComicPages, maxDimension: Int = defaultMaxDimension) {
        self.archive = archive
        self.maxDimension = maxDimension
        cache.totalCostLimit = PageLoader.defaultCacheBytes()
    }

    var pageCount: Int { archive.pageCount }

    /// Returns the (possibly cached) decoded image for [index], downsampled to the long-edge limit,
    /// or with [fitWidth] to the limit on its short edge, so a tall webtoon strip keeps its width.
    func loadPage(_ index: Int, fitWidth: Bool = false) -> CGImage? {
        let key = NSNumber(value: fitWidth ? ~index : index)   // ~index: its own cache slot
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = lock.withLock({ try? archive.readPage(index) }),
              let image = PageLoader.decodeSampled(data: data, maxDim: maxDimension, shortEdge: fitWidth) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Decodes [data], downsampled so its long edge fits [maxDim] using the same power-of-two rule
    /// as Android's BitmapFactory inSampleSize (so output dimensions match across platforms).
    static func decodeSampled(data: Data, maxDim: Int, shortEdge: Bool = false) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        // Pixel dimensions without allocating the full bitmap (mirrors inJustDecodeBounds).
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let longEdge = max(w, h)

        let sample = computeInSampleSize(longEdge: shortEdge ? min(w, h) : longEdge, maxDim: maxDim)
        // Target long edge after power-of-two sampling — equals Android's downsampled long edge.
        let targetLong = sample > 1 ? longEdge / sample : longEdge

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetLong, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil) // fallback: full decode
    }

    private static func defaultCacheBytes() -> Int {
        // A quarter of physical memory, capped — same divisor and cap Android applies to its heap
        // (PageConstants is the shared source of truth; only the memory source differs per platform).
        let quarter = Int(ProcessInfo.processInfo.physicalMemory) / PageConstants.cacheMemoryDivisor
        return min(quarter, PageConstants.cacheMaxBytes)
    }
}
