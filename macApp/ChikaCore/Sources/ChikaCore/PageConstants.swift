/// Single source of truth for page decoding/caching, shared by every platform so all downsample to
/// the same dimensions and size their page cache with the same formula. Only the available-memory
/// *source* differs per platform (JVM heap on Android, physical RAM on Apple) — that is unavoidable;
/// the divisor and cap live here so the budgeting logic itself can't drift.
public enum PageConstants {
    /// Long-edge pixel limit for a decoded page; larger scans are downsampled to this.
    public static let maxPageDimension = 2560

    /// Spend 1/`cacheMemoryDivisor` of available memory on the page cache.
    public static let cacheMemoryDivisor = 4

    /// Hard upper bound on the page cache, in bytes (512 MB).
    public static let cacheMaxBytes = 512 * 1024 * 1024
}

/// Largest power-of-two sample factor keeping the long edge at or above `maxDim` — identical to
/// Android's computeInSampleSize, so every platform downsamples to the same dimensions.
public func computeInSampleSize(longEdge: Int, maxDim: Int) -> Int {
    if longEdge <= maxDim || longEdge <= 0 { return 1 }
    var sample = 1
    while longEdge / (sample * 2) >= maxDim { sample *= 2 }
    return sample
}
