package com.chakra.comicreader.data.page

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import com.chakra.comicreader.data.archive.ComicArchive
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Decodes comic pages to [Bitmap]s, downsampling large scans so they fit within [maxDimensionPx]
 * on the long edge. This keeps memory bounded (full-res comic scans are frequently 2000–4000px and
 * would otherwise blow the heap) while leaving enough resolution that zooming into a single panel
 * still looks crisp.
 *
 * A small [LruCache] keeps recently viewed pages hot so back/forward navigation is instant. One
 * [PageLoader] is created per open comic and [close]d with it.
 */
class PageLoader(
    private val archive: ComicArchive,
    private val maxDimensionPx: Int = DEFAULT_MAX_DIMENSION,
    cacheBytes: Int = defaultCacheBytes(),
) {
    private val decodeMutex = Mutex()

    private val cache = object : LruCache<Int, Bitmap>(cacheBytes) {
        override fun sizeOf(key: Int, value: Bitmap): Int = value.byteCount
    }

    val pageCount: Int get() = archive.pageCount

    /** Returns the (possibly cached) decoded bitmap for [index], downsampled to [maxDimensionPx]. */
    suspend fun loadPage(index: Int): Bitmap = withContext(Dispatchers.IO) {
        cache.get(index)?.let { return@withContext it }
        // Serialize archive reads: junrar's Archive is not thread-safe, and serializing decode
        // also prevents two prefetches from decoding the same page twice.
        decodeMutex.withLock {
            cache.get(index)?.let { return@withLock it }
            val bytes = archive.readPage(index)
            val bitmap = decodeSampled(bytes, maxDimensionPx)
            cache.put(index, bitmap)
            bitmap
        }
    }

    /** Decodes only the dimensions of page [index] without allocating the full bitmap. */
    suspend fun pageSize(index: Int): IntArray = withContext(Dispatchers.IO) {
        decodeMutex.withLock {
            val bytes = archive.readPage(index)
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            intArrayOf(opts.outWidth, opts.outHeight)
        }
    }

    fun evictAll() = cache.evictAll()

    fun close() {
        cache.evictAll()
        runCatching { archive.close() }
    }

    private fun decodeSampled(bytes: ByteArray, maxDim: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)

        val opts = BitmapFactory.Options().apply {
            inSampleSize = computeInSampleSize(bounds.outWidth, bounds.outHeight, maxDim)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            ?: throw IllegalStateException("Failed to decode page (corrupt or unsupported image)")
    }

    private fun computeInSampleSize(width: Int, height: Int, maxDim: Int): Int {
        val longEdge = maxOf(width, height)
        if (longEdge <= maxDim || longEdge <= 0) return 1
        var sample = 1
        while (longEdge / (sample * 2) >= maxDim) sample *= 2
        return sample
    }

    companion object {
        const val DEFAULT_MAX_DIMENSION = 2560

        fun defaultCacheBytes(): Int {
            val maxMemKb = (Runtime.getRuntime().maxMemory() / 1024L).toInt()
            return (maxMemKb / 4) * 1024 // a quarter of the heap, in bytes
        }
    }
}
