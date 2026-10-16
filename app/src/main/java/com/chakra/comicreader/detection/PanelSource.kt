package com.chakra.comicreader.detection

import android.graphics.Bitmap

/**
 * Something that finds the panels on a page. Implementations: [MlPanelDetector] (TFLite) and
 * [NoopPanelSource] (whole page only).
 *
 * Returns panels in reading order, normalized to `[0, 1]`. Should return a single full-page panel
 * when it can't confidently find ≥2 panels, so the reader always has something to show.
 * Returns null when detection itself failed (as opposed to finding nothing), so callers show the
 * whole page without caching the failure as if it were a real result.
 */
interface PanelSource {
    fun detect(page: Bitmap, rightToLeft: Boolean = false): List<Panel>?
}

/** Used when no detector is available; the reader just shows whole pages. */
object NoopPanelSource : PanelSource {
    override fun detect(page: Bitmap, rightToLeft: Boolean): List<Panel>? = listOf(Panel.FULL_PAGE)
}
