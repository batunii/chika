package com.chakra.comicreader.ui.reader

import com.chakra.comicreader.detection.Panel
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CameraTransformTest {

    private fun assertNear(expected: Float, actual: Float, tolerance: Float = 0.001f) {
        assertTrue(abs(expected - actual) <= tolerance, "expected $expected, got $actual")
    }

    @Test
    fun fullPageContainFitCentersThePage() {
        // 1000x1500 page in a 500x500 container, fill = 1: height limits, scale = 1/3.
        val draw = computePageDraw(Panel.FULL_PAGE, 1000, 1500, 500f, 500f, fill = 1f)
        assertNear(1000f / 3f, draw.scaledWidth)
        assertNear(500f, draw.scaledHeight)
        assertNear((500f - 1000f / 3f) / 2f, draw.left) // centered horizontally
        assertNear(0f, draw.top)
    }

    @Test
    fun panelRegionFillsContainerAndIsCentered() {
        // Left half of a square page in a square container: the camera region (500x1000 px)
        // is framed so its centre lands at the container centre.
        val camera = Panel(0f, 0f, 0.5f, 1f)
        val draw = computePageDraw(camera, 1000, 1000, 400f, 400f, fill = 1f)
        // Scale fits the 500x1000 region into 400x400 → 0.4; page becomes 400x400... scaled by
        // bitmap: scaledWidth = 1000*0.4 = 400.
        assertNear(400f, draw.scaledWidth)
        assertNear(400f, draw.scaledHeight)
        // Camera centre (250, 500) in bitmap px must map to container centre (200, 200).
        assertNear(200f - 250f * 0.4f, draw.left)
        assertNear(200f - 500f * 0.4f, draw.top)
    }

    @Test
    fun fillFactorLeavesPadding() {
        val padded = computePageDraw(Panel.FULL_PAGE, 1000, 1000, 500f, 500f, fill = 0.9f)
        assertNear(450f, padded.scaledWidth)
        assertNear(450f, padded.scaledHeight)
    }

    @Test
    fun degenerateBitmapAndCameraSizesDoNotBlowUp() {
        val draw = computePageDraw(Panel(0.5f, 0.5f, 0.5f, 0.5f), 0, 0, 100f, 100f)
        assertTrue(draw.scaledWidth.isFinite())
        assertTrue(draw.scaledHeight.isFinite())
        assertTrue(draw.left.isFinite())
        assertTrue(draw.top.isFinite())
    }

    @Test
    fun horizontalClampCentersWhenImageFitsAndBoundsWhenWider() {
        assertNear(50f, clampPanHorizontal(pan = 999f, base = 0f, size = 100f, container = 200f))
        assertNear(0f, clampPanHorizontal(pan = 500f, base = 0f, size = 300f, container = 200f))
        assertNear(-100f, clampPanHorizontal(pan = -500f, base = 0f, size = 300f, container = 200f))
    }

    @Test
    fun verticalClampKeepsASliverOnScreen() {
        val keep = ReaderGestureConfig.minVisibleFraction * 100f // size 100 < container 400
        assertNear(400f - keep, clampPanVertical(pan = 9999f, base = 0f, size = 100f, container = 400f))
        assertNear(keep - 100f, clampPanVertical(pan = -9999f, base = 0f, size = 100f, container = 400f))
        assertNear(10f, clampPanVertical(pan = 10f, base = 0f, size = 100f, container = 400f))
    }
}
