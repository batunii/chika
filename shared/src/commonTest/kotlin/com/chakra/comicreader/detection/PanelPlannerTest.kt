package com.chakra.comicreader.detection

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PanelPlannerTest {

    private val pageW = 1000
    private val pageH = 1500

    private fun plan(
        panels: List<Panel>,
        bubbles: List<Panel> = emptyList(),
        rightToLeft: Boolean = false,
    ) = PanelPlanner.plan(panels, bubbles, pageW, pageH, rightToLeft)

    @Test
    fun emptyInputPassesThrough() {
        assertEquals(emptyList(), plan(emptyList()))
    }

    @Test
    fun normalPanelsAreLeftAsIs() {
        // Area ~0.2 each: neither small (<0.10) nor big (>0.35).
        val a = Panel(0.0f, 0.0f, 0.5f, 0.4f)
        val b = Panel(0.5f, 0.0f, 1.0f, 0.4f)
        assertEquals(listOf(a, b), plan(listOf(a, b)))
    }

    @Test
    fun adjacentSmallPanelsMergeIntoOneRegion() {
        // Three tiny side-by-side panels in one strip (area 0.03 each, gaps < 0.05).
        val p1 = Panel(0.00f, 0.0f, 0.15f, 0.2f)
        val p2 = Panel(0.17f, 0.0f, 0.32f, 0.2f)
        val p3 = Panel(0.34f, 0.0f, 0.49f, 0.2f)
        val result = plan(listOf(p1, p2, p3))
        assertEquals(1, result.size)
        assertEquals(Panel(0.00f, 0.0f, 0.49f, 0.2f), result.single())
    }

    @Test
    fun mergeStopsAtMaxMergeCount() {
        // Four tiny adjacent panels; default cap is 3, so the run chunks 3 + 1.
        val panels = (0 until 4).map { i ->
            Panel(i * 0.12f, 0.0f, i * 0.12f + 0.10f, 0.2f)
        }
        val result = plan(panels)
        assertEquals(2, result.size)
        assertEquals(panels[0].left, result[0].left)
        assertEquals(panels[2].right, result[0].right)
        assertEquals(panels[3], result[1])
    }

    @Test
    fun distantSmallPanelsDoNotMerge() {
        val p1 = Panel(0.0f, 0.0f, 0.15f, 0.2f)
        val p2 = Panel(0.5f, 0.0f, 0.65f, 0.2f) // gap 0.35 >> adjacencyGap
        assertEquals(listOf(p1, p2), plan(listOf(p1, p2)))
    }

    @Test
    fun bigWidePanelIsDividedWithVerticalCut() {
        // Area 0.5, pixel aspect (0.9/0.55)*(1000/1500) ≈ 1.09... make it clearly wide:
        // width 0.95, height 0.4 → area 0.38 > 0.35; aspect (0.95/0.4)*(2/3) ≈ 1.58 > 1.25.
        val wide = Panel(0.0f, 0.0f, 0.95f, 0.4f)
        val result = plan(listOf(wide))
        assertEquals(2, result.size)
        val (first, second) = result
        assertEquals(wide.left, first.left)
        assertEquals(wide.right, second.right)
        assertEquals(first.right, second.left) // pieces share the cut
        assertEquals(wide.top, first.top)
        assertEquals(wide.bottom, first.bottom)
    }

    @Test
    fun rightToLeftDivisionEmitsRightPieceFirst() {
        val wide = Panel(0.0f, 0.0f, 0.95f, 0.4f)
        val result = plan(listOf(wide), rightToLeft = true)
        assertEquals(2, result.size)
        assertTrue(result[0].left > result[1].left)
    }

    @Test
    fun bigSquarePanelIsTreatedAsSplashAndKept() {
        // Pixel aspect (0.75/0.5)*(1000/1500) = 1.0 → square; area 0.375 > 0.35 but never divided.
        val splash = Panel(0.1f, 0.2f, 0.85f, 0.7f)
        assertEquals(listOf(splash), plan(listOf(splash)))
    }

    @Test
    fun cutAvoidsBubblesByFallingInLargestGap() {
        val wide = Panel(0.0f, 0.0f, 0.95f, 0.4f)
        // Two bubble groups: one on the far left, one on the far right; gap centre ≈ 0.475.
        val bubbles = listOf(
            Panel(0.05f, 0.1f, 0.30f, 0.3f),
            Panel(0.65f, 0.1f, 0.90f, 0.3f),
        )
        val result = plan(listOf(wide), bubbles = bubbles)
        assertEquals(2, result.size)
        val cut = result[0].right
        assertEquals(0.475f, cut, absoluteTolerance = 0.01f)
        // The cut must not slice through either bubble.
        for (bubble in bubbles) {
            assertTrue(cut <= bubble.left || cut >= bubble.right, "cut $cut slices bubble $bubble")
        }
    }

    @Test
    fun fullWidthBroadPanelSplitsIntoFour() {
        // Full width (0.96) AND broad/tall (0.75) → 2×2 grid, read TL, TR, BL, BR.
        val p = Panel(0.0f, 0.10f, 0.96f, 0.85f)
        val r = plan(listOf(p))
        assertEquals(4, r.size)
        // corners
        assertEquals(p.left, r[0].left); assertEquals(p.top, r[0].top)      // TL
        assertEquals(p.right, r[1].right); assertEquals(p.top, r[1].top)    // TR
        assertEquals(p.left, r[2].left); assertEquals(p.bottom, r[2].bottom) // BL
        assertEquals(p.right, r[3].right); assertEquals(p.bottom, r[3].bottom) // BR
        // shared cuts
        assertEquals(r[0].right, r[1].left)  // vertical cut
        assertEquals(r[0].bottom, r[2].top)  // horizontal cut
        assertEquals(r[1].bottom, r[3].top)
    }

    @Test
    fun fullWidthShortPanelStillSplitsIntoTwo() {
        // Full width (0.95) but short (0.30, not broad) → 2 side-by-side.
        val p = Panel(0.0f, 0.0f, 0.95f, 0.30f)
        val r = plan(listOf(p))
        assertEquals(2, r.size)
        assertEquals(r[0].right, r[1].left)
    }

    @Test
    fun doublePageBroadPanelSplitsIntoEight() {
        // Landscape spread image (aspect 2200/1500 ≈ 1.47); a panel spanning both pages, broad.
        val spread = Panel(0.0f, 0.10f, 1.0f, 0.85f)
        val r = PanelPlanner.plan(listOf(spread), emptyList(), 2200, 1500, false)
        assertEquals(8, r.size)
        // first 4 belong to the left page, next 4 to the right page
        assertTrue(r.take(4).all { it.right <= 0.5f + 1e-4f }, "first 4 should be the left page")
        assertTrue(r.drop(4).all { it.left >= 0.5f - 1e-4f }, "last 4 should be the right page")
    }

    @Test
    fun doublePageShortPanelSplitsIntoFour() {
        // Spread, but the cross-page panel is short → each half halves → 2 + 2 = 4.
        val spread = Panel(0.0f, 0.30f, 1.0f, 0.60f)
        val r = PanelPlanner.plan(listOf(spread), emptyList(), 2200, 1500, false)
        assertEquals(4, r.size)
        assertTrue(r.take(2).all { it.right <= 0.5f + 1e-4f })
        assertTrue(r.drop(2).all { it.left >= 0.5f - 1e-4f })
    }

    @Test
    fun doublePageRightToLeftEmitsRightPageFirst() {
        val spread = Panel(0.0f, 0.30f, 1.0f, 0.60f)
        val r = PanelPlanner.plan(listOf(spread), emptyList(), 2200, 1500, true)
        assertEquals(4, r.size)
        assertTrue(r.take(2).all { it.left >= 0.5f - 1e-4f }, "RTL: right page first")
    }

    private fun assertEquals(expected: Float, actual: Float, absoluteTolerance: Float, message: String? = null) {
        assertTrue(
            kotlin.math.abs(expected - actual) <= absoluteTolerance,
            message ?: "expected $expected within $absoluteTolerance of $actual",
        )
    }
}
