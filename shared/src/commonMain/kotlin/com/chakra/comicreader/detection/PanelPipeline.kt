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
        val ordered = PanelOrdering.order(panels, rightToLeft)
        return PanelPlanner.plan(ordered, bubbles, pageW, pageH, rightToLeft)
    }
}
