package com.napkin.comicreader.detection

import android.graphics.Bitmap

/**
 * Something that finds the panels on a page. Implementations: [MlPanelDetector] (TFLite, primary),
 * [PanelDetector] (classical CV, fallback), and [NoopPanelSource] (whole page only).
 *
 * Returns panels in reading order, normalized to `[0, 1]`. Should return a single full-page panel
 * when it can't confidently find ≥2 panels, so the reader always has something to show.
 */
interface PanelSource {
    fun detect(page: Bitmap, rightToLeft: Boolean = false): List<Panel>
}

/** Used when no detector is available; the reader just shows whole pages. */
object NoopPanelSource : PanelSource {
    override fun detect(page: Bitmap, rightToLeft: Boolean): List<Panel> = listOf(Panel.FULL_PAGE)
}
