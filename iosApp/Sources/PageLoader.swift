import UIKit
import ImageIO
import ChikaShared

/// Decodes comic pages to UIImages, downsampling very large scans and keeping recently viewed pages
/// hot in an LRU cache so back/forward navigation is instant and memory stays bounded.
///
/// This deliberately mirrors Android's PageLoader byte-for-byte in the part that matters for
/// detection parity: the same long-edge limit (2560) and the same power-of-two sampling rule, so a
/// page is downsampled to the SAME dimensions on both platforms (and, like Android, typical
/// 2000–4000px manga is left at full resolution — sampling only kicks in above ~5120px). The
/// detector letterboxes from these dimensions, so matching them keeps detections identical across
/// platforms. One PageLoader is created per open comic.
final class PageLoader {
    private let archive: CbzArchive
    private let maxDimension: Int
    private let cache = NSCache<NSNumber, UIImage>()
    // ZIPFoundation's Archive isn't thread-safe; serialize reads (and avoid decoding a page twice
    // when the current load and a prefetch race for it).
    private let lock = NSLock()

    static let defaultMaxDimension = Int(PageConstants.shared.maxPageDimension)

    init(archive: CbzArchive, maxDimension: Int = defaultMaxDimension) {
        self.archive = archive
        self.maxDimension = maxDimension
        cache.totalCostLimit = PageLoader.defaultCacheBytes()
    }

    var pageCount: Int { archive.pageCount }

    /// Returns the (possibly cached) decoded image for [index], downsampled to the long-edge limit.
    func loadPage(_ index: Int) -> UIImage? {
        let key = NSNumber(value: index)
        if let hit = cache.object(forKey: key) { return hit }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = try? archive.readPage(index),
              let image = PageLoader.decodeSampled(data: data, maxDim: maxDimension) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale) * 4
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Decodes [data], downsampled so its long edge fits [maxDim] using the same power-of-two rule
    /// as Android's BitmapFactory inSampleSize (so output dimensions match across platforms).
    static func decodeSampled(data: Data, maxDim: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return UIImage(data: data) }

        // Pixel dimensions without allocating the full bitmap (mirrors inJustDecodeBounds).
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let longEdge = max(w, h)

        let sample = Int(PageSampling.shared.sampleSize(longEdge: Int32(longEdge), maxDim: Int32(maxDim)))
        // Target long edge after power-of-two sampling — equals Android's downsampled long edge.
        let targetLong = sample > 1 ? longEdge / sample : longEdge

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetLong, 1),
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data) // fallback: full decode
    }

    private static func defaultCacheBytes() -> Int {
        // A quarter of physical memory, capped — same divisor and cap Android applies to its heap
        // (PageConstants is the shared source of truth; only the memory source differs per platform).
        let quarter = Int(ProcessInfo.processInfo.physicalMemory) / Int(PageConstants.shared.cacheMemoryDivisor)
        return min(quarter, Int(PageConstants.shared.cacheMaxBytes))
    }
}
