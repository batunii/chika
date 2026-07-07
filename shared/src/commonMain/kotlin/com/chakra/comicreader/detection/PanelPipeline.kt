package com.chakra.comicreader.detection

/**
 * The full shared post-detection pipeline in one call: raw detected boxes go in, final zoom
 * regions in reading order come out. Platform readers (Android ViewModel, iOS app) should call
 * this rather than composing [PanelOrdering] and [PanelPlanner] themselves so both stay in sync.
 */
object PanelPipeline {
    /**
     * Each framed panel is grown by this fraction of its own size on every side, so the reader shows
     * a little context around it instead of hugging the detected box edge-to-edge. Detected boxes run
     * tight and clip overflowing speech bubbles / furigana / SFX; this breathing room brings them back
     * into frame. At the reader's `fill = 0.98` framing, ~5.7% per side leaves the *original* panel
     * filling ~88% of the screen (a ~12% gap). Only real panels are padded — the whole-page intro/outro
     * slots the reader synthesizes aren't in this list, so they still fill the screen.
     */
    private const val PANEL_MARGIN = 0.057f

    fun zoomRegions(
        panels: List<Panel>,
        bubbles: List<Panel>,
        pageW: Int,
        pageH: Int,
        rightToLeft: Boolean,
    ): List<Panel> {
        // Add any large, roughly-rectangular region the model left uncovered as a panel, so missed
        // panels get numbered too — then order and plan as usual.
        // Manga (read right-to-left) is paced panel-by-panel, so it uses a profile that merges far
        // less aggressively; Western LTR comics keep the default grid-friendly merging.
        val config = if (rightToLeft) PanelPlanner.Config.MANGA else PanelPlanner.Config()
        val filled = PanelGapFiller.fill(panels)
        val ordered = PanelOrdering.order(filled, rightToLeft)
        val planned = PanelPlanner.plan(ordered, bubbles, pageW, pageH, rightToLeft, config)
        if (planned.size >= 2) return pad(planned)
        // The model found nothing usable (or it collapsed to a single region): rather than show the
        // page as one panel, treat the whole page as a panel and let the ratio splitter break it up.
        return pad(PanelPlanner.plan(listOf(Panel.FULL_PAGE), bubbles, pageW, pageH, rightToLeft, config))
    }

    /** Grows each panel by [PANEL_MARGIN] of its own size per side, clamped to the page. */
    private fun pad(panels: List<Panel>): List<Panel> = panels.map { p ->
        val dx = p.width * PANEL_MARGIN
        val dy = p.height * PANEL_MARGIN
        Panel(
            (p.left - dx).coerceAtLeast(0f),
            (p.top - dy).coerceAtLeast(0f),
            (p.right + dx).coerceAtMost(1f),
            (p.bottom + dy).coerceAtMost(1f),
        )
    }
}
