package com.chakra.comicreader.detection

import kotlin.test.Test
import kotlin.test.assertEquals

class PanelPipelineTest {

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
        assertEquals(manual, viaPipeline)
    }
}
