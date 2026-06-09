package com.chakra.comicreader.detection

/**
 * A detected panel as a rectangle in normalized page coordinates: each edge is a fraction in
 * `[0, 1]` of the page width/height. Normalized coordinates make panels independent of the
 * resolution the page happened to be decoded/detected at, so the reader can map them onto a bitmap
 * of any size.
 */
data class Panel(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
    val width: Float get() = (right - left).coerceAtLeast(0f)
    val height: Float get() = (bottom - top).coerceAtLeast(0f)
    val area: Float get() = width * height
    val centerX: Float get() = (left + right) / 2f
    val centerY: Float get() = (top + bottom) / 2f

    /** A panel covering the whole page, used as the per-page "zoomed-out" view and as a fallback. */
    companion object {
        val FULL_PAGE = Panel(0f, 0f, 1f, 1f)
    }
}
