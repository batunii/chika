package com.chakra.comicreader.detection

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PanelGapFillerTest {

    @Test
    fun emptyInputIsUnchanged() {
        assertEquals(emptyList(), PanelGapFiller.fill(emptyList()))
    }

    @Test
    fun bigRectangularLeftoverBecomesAPanel() {
        // One panel covers the top 40%; the bottom 60% is a missed panel.
        val top = Panel(0.0f, 0.0f, 1.0f, 0.40f)
        val result = PanelGapFiller.fill(listOf(top))
        assertEquals(2, result.size)
        val gap = result.last()
        assertTrue(gap.top in 0.35f..0.45f, "gap top=$gap")
        assertTrue(gap.bottom >= 0.95f, "gap bottom=$gap")
        assertTrue(gap.width >= 0.95f, "gap width=$gap")
    }

    @Test
    fun missedPanelSurroundedByMarginsIsStillRecovered() {
        // The realistic case: panels don't reach the page edges, so a margin frame surrounds and
        // connects every uncovered cell. A detected panel sits in the top ~45%; the bottom panel is
        // missed. The largest empty rectangle must isolate the missed bottom region despite margins.
        val detectedTop = Panel(0.04f, 0.04f, 0.96f, 0.46f)
        val result = PanelGapFiller.fill(listOf(detectedTop))
        assertEquals(2, result.size)
        val gap = result.last()
        assertTrue(gap.top in 0.40f..0.55f, "gap top=$gap")
        assertTrue(gap.bottom >= 0.95f, "gap bottom=$gap")
        assertTrue(gap.width >= 0.90f, "gap width=$gap")
    }

    @Test
    fun smallLeftoverBelowThresholdIsIgnored() {
        // Only a ~3% strip at the bottom is uncovered — below the 5% area threshold.
        val p = Panel(0.0f, 0.0f, 1.0f, 0.97f)
        assertEquals(1, PanelGapFiller.fill(listOf(p)).size)
    }

    @Test
    fun thinMarginFrameIsIgnored() {
        // A centred panel with realistic ~4% margins: every leftover strip is too thin to be a panel.
        val center = Panel(0.04f, 0.04f, 0.96f, 0.96f)
        assertEquals(1, PanelGapFiller.fill(listOf(center)).size)
    }

    @Test
    fun missedPanelIsNumberedByThePipeline() {
        // Top panel + a big uncovered bottom: the pipeline should yield at least 2 regions in order.
        val top = Panel(0.0f, 0.0f, 1.0f, 0.35f)
        val regions = PanelPipeline.zoomRegions(listOf(top), emptyList(), 1000, 1500, rightToLeft = false)
        assertTrue(regions.size >= 2, "expected the gap to be added; got $regions")
        // Reading order: the top region comes before the filled bottom one.
        assertTrue(regions.first().top <= regions.last().top)
    }
}
