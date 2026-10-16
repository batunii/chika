package com.chakra.comicreader.ui.reader

import com.chakra.comicreader.detection.Panel

/**
 * Where to draw the full page bitmap (top-left + scaled size, in container pixels) so that a given
 * [Panel] region fills the container with "contain" fit (whole panel visible, aspect preserved,
 * centered). The same math handles the full-page view (panel = whole page) and any sub-panel.
 */
data class PageDraw(
    val left: Float,
    val top: Float,
    val scaledWidth: Float,
    val scaledHeight: Float,
)

/**
 * Computes the [PageDraw] that frames [camera] (a normalized page rect) inside a container of size
 * [containerW] x [containerH], given the page bitmap's pixel size. [fill] < 1 leaves padding around
 * the framed region so panels don't touch the screen edges.
 */
fun computePageDraw(
    camera: Panel,
    bitmapW: Int,
    bitmapH: Int,
    containerW: Float,
    containerH: Float,
    fill: Float = 0.98f,
): PageDraw {
    val bw = bitmapW.toFloat().coerceAtLeast(1f)
    val bh = bitmapH.toFloat().coerceAtLeast(1f)

    // Camera region in bitmap pixels.
    val camW = (camera.width * bw).coerceAtLeast(1f)
    val camH = (camera.height * bh).coerceAtLeast(1f)
    val camCx = camera.centerX * bw
    val camCy = camera.centerY * bh

    // Scale so the camera region fits the container (contain), with a little padding.
    val scale = minOf(containerW / camW, containerH / camH) * fill

    val scaledWidth = bw * scale
    val scaledHeight = bh * scale
    val left = containerW / 2f - camCx * scale
    val top = containerH / 2f - camCy * scale

    return PageDraw(left, top, scaledWidth, scaledHeight)
}

/** Gesture tuning shared by both readers (so pinch, pan and flick feel identical). */
object ReaderGestureConfig {
    /** Min horizontal release speed (px/s) for a one-finger drag to count as a page-turn flick. */
    val flickVelocityPxS: Float = 700f

    /** A flick must be this many times more horizontal than vertical to turn the page. */
    val swipeHorizontalBias: Float = 1.2f

    /** Fraction of the comic kept on screen when dragged off the top/bottom, so it can't be lost. */
    val minVisibleFraction: Float = 0.15f

    val minZoom: Float = 1f
    val maxZoom: Float = 5f
}

/**
 * Horizontal clamp ("cover"): the comic never exposes background to its left or right. When wider
 * than the screen (zoomed) it pans only until an edge meets the screen edge; when it fits, it's
 * centered. [base] is the image's left at zero pan, [size] its scaled width, [container] the width.
 */
fun clampPanHorizontal(pan: Float, base: Float, size: Float, container: Float): Float {
    if (size <= container) return (container - size) / 2f - base
    return pan.coerceIn(container - size - base, -base)
}

/**
 * Vertical clamp ("float over background"): the comic may move freely up/down — even past the top or
 * bottom edge — but at least [ReaderGestureConfig.minVisibleFraction] of it stays on screen.
 * [base] is the image's top at zero pan, [size] its scaled height, [container] the height.
 */
fun clampPanVertical(pan: Float, base: Float, size: Float, container: Float): Float {
    val keep = ReaderGestureConfig.minVisibleFraction * minOf(size, container)
    return pan.coerceIn(keep - size - base, container - keep - base)
}
