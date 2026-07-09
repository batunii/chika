package com.chakra.comicreader.detection

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PanelPipelineTest {

    @Test
    fun pageWithNoDetectedPanelsIsBrokenUpNotShownWhole() {
        // When the model returns nothing, the whole page should still be split into zoom regions
        // (a portrait page is full-width + broad ⇒ a 2×2 quarter), never shown as a single panel.
        val regions = PanelPipeline.zoomRegions(emptyList(), emptyList(), 1000, 1500, rightToLeft = false)
        assertTrue(regions.size >= 2, "a page with no detections should be broken up; got $regions")
    }

    @Test
    fun pipelineMatchesOrderingThenPlanning() {
        val shuffled = listOf(
            Panel(0.55f, 0.5f, 1.0f, 1.0f),
            Panel(0.0f, 0.0f, 0.45f, 0.4f),
            Panel(0.0f, 0.5f, 0.45f, 1.0f),
            Panel(0.55f, 0.0f, 1.0f, 0.4f),
        )
        val bubbles = listOf(Panel(0.1f, 0.1f, 0.2f, 0.2f))

        val viaPipeline = PanelPipeline.zoomRegions(shuffled, bubbles, 1000, 1500, rightToLeft = false)
        val manual = PanelPlanner.plan(
            PanelOrdering.order(shuffled, rightToLeft = false),
            bubbles, 1000, 1500, rightToLeft = false,
        )
        // The pipeline is ordering → planning → a small outward pad (breathing room for overflowing
        // text). So it must keep the same count and order, and each region must CONTAIN its planned
        // counterpart (padding only grows, clamped to the page) — never shrink or reorder.
        assertEquals(manual.size, viaPipeline.size, "pipeline should preserve the planned region count")
        for (i in manual.indices) {
            val m = manual[i]
            val v = viaPipeline[i]
            assertTrue(
                v.left <= m.left + 1e-4f && v.top <= m.top + 1e-4f &&
                    v.right >= m.right - 1e-4f && v.bottom >= m.bottom - 1e-4f,
                "pipeline region $i should be a padded superset of the planned region: $v vs $m",
            )
        }
    }
}
