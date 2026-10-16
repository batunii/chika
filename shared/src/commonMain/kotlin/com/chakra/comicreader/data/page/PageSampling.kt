package com.chakra.comicreader.data.page

/**
 * The power-of-two downsampling rule for decoding pages, shared by Android (BitmapFactory
 * `inSampleSize`) and iOS (ImageIO target size) so both platforms decode a page to the SAME
 * dimensions — the detector letterboxes from those dimensions, so they must match.
 */
object PageSampling {
    /**
     * Largest power-of-two sample factor that keeps the long edge at or above [maxDim]. Note this
     * means a decoded page's long edge lands in `[maxDim, 2*maxDim)`, not strictly below [maxDim].
     */
    fun sampleSize(longEdge: Int, maxDim: Int): Int {
        if (longEdge <= maxDim || longEdge <= 0) return 1
        var sample = 1
        while (longEdge / (sample * 2) >= maxDim) sample *= 2
        return sample
    }
}
