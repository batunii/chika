package com.chakra.comicreader.detection

/**
 * The full shared post-detection pipeline in one call: raw detected boxes go in, final zoom
 * regions in reading order come out. Platform readers (Android ViewModel, iOS app) should call
 * this rather than composing [PanelOrdering] and [PanelPlanner] themselves so both stay in sync.
 */
object PanelPipeline {
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
        if (planned.size >= 2) return planned
        // The model found nothing usable (or it collapsed to a single region): rather than show the
        // page as one panel, treat the whole page as a panel and let the ratio splitter break it up.
        return PanelPlanner.plan(listOf(Panel.FULL_PAGE), bubbles, pageW, pageH, rightToLeft, config)
    }
}
