package com.chakra.comicreader.detection

import com.chakra.comicreader.ui.reader.computePageDraw
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Regression pin from the July 2026 iOS framing investigation: the raw detections for Vinland
 * Saga v01 p159 (a 7-panel RTL page whose first panel is the tall top-right "woman behind the
 * curtain") must plan into 7 regions whose first camera nearly fills a phone screen. The on-device
 * render was observed diverging from this exact math, so this test pins what the shared pipeline
 * *should* hand every platform for that page.
 */
class DevicePageDiagnosticTest {
    @Test
    fun v01p159PlansSevenRegionsAndPanel1FillsAPhoneScreen() {
        val pageW = 3412
        val pageH = 4800
        val panels = listOf(
            Panel(0.5869f, 0.6130f, 0.8878f, 0.7897f),
            Panel(0.0010f, 0.4301f, 0.5726f, 0.7672f),
            Panel(0.0015f, 0.0004f, 0.6271f, 0.4155f),
            Panel(0.6374f, 0.0005f, 0.8879f, 0.4146f),
            Panel(0.5857f, 0.8015f, 0.8900f, 0.9998f),
            Panel(0.0016f, 0.7829f, 0.5729f, 1.0000f),
            Panel(0.5839f, 0.4286f, 0.8882f, 0.5984f),
        )
        val bubbles = listOf(
            Panel(0.4279f, 0.8062f, 0.5558f, 0.9271f),
            Panel(0.0991f, 0.0970f, 0.2187f, 0.1784f),
            Panel(0.3831f, 0.0950f, 0.4623f, 0.1481f),
            Panel(0.1765f, 0.7897f, 0.2379f, 0.8718f),
            Panel(0.6528f, 0.3102f, 0.7328f, 0.4064f),
            Panel(0.0738f, 0.2309f, 0.1376f, 0.2454f),
            Panel(0.6560f, 0.8147f, 0.6728f, 0.8363f),
        )
        val planned = PanelPipeline.zoomRegions(panels, bubbles, pageW, pageH, rightToLeft = true)
        assertEquals(7, planned.size)

        // First region in RTL order is the padded tall top-right panel.
        val first = planned[0]
        assertTrue(abs(first.left - 0.6231f) < 0.01f, "region 1 left drifted: ${first.left}")
        assertTrue(first.top == 0f, "region 1 top should clamp to the page top: ${first.top}")
        assertTrue(abs(first.right - 0.9022f) < 0.01f, "region 1 right drifted: ${first.right}")
        assertTrue(abs(first.bottom - 0.4382f) < 0.01f, "region 1 bottom drifted: ${first.bottom}")

        // Framed on an iPhone 12/13 Pro Max screen the panel nearly fills it: the page draws with
        // its top just below the screen top, not floating a third of the way down.
        val draw = computePageDraw(first, pageW, pageH, 428f, 926f, 0.98f)
        assertTrue(draw.top in 0f..20f, "page top should sit near the screen top, was ${draw.top}")
        val panelLeftOnScreen = draw.left + 0.6374f * draw.scaledWidth
        val panelRightOnScreen = draw.left + 0.8879f * draw.scaledWidth
        val widthFraction = (panelRightOnScreen - panelLeftOnScreen) / 428f
        assertTrue(widthFraction > 0.8f, "panel should fill most of the width, filled $widthFraction")
    }
}
