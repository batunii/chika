package com.chakra.comicreader.data.page

/**
 * Single source of truth for page decoding/caching, shared by Android and iOS so both platforms
 * downsample to the same dimensions and size their page cache with the same formula. Only the
 * available-memory *source* differs per platform (JVM heap on Android, physical RAM on iOS) — that
 * is unavoidable; the divisor and cap live here so the budgeting logic itself can't drift.
 */
object PageConstants {
    /** Long-edge pixel limit for a decoded page; larger scans are downsampled to this. */
    val maxPageDimension: Int = 2560

    /** Spend 1/[cacheMemoryDivisor] of available memory on the page cache. */
    val cacheMemoryDivisor: Int = 4

    /** Hard upper bound on the page cache, in bytes (512 MB). */
    val cacheMaxBytes: Int = 512 * 1024 * 1024

    /**
     * Floor for the page cache, in bytes (128 MB ≈ two worst-case decoded pages). Pages decode up to
     * just under 2×[maxPageDimension] on the long edge (~70 MB ARGB); with a smaller budget one page
     * exceeds the cache, so it evicts itself and every prefetch is decoded twice.
     */
    val cacheMinBytes: Int = 128 * 1024 * 1024

    /** Largest single archive entry (encoded page) we will read into memory: 100 MB. A bigger
     *  entry is corrupt or hostile (a real page is a few MB); reading it would OOM the app. */
    val maxPageBytes: Int = 100 * 1024 * 1024
}
