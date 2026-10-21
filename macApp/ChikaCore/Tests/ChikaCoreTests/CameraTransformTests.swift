import Testing
import ChikaCore

struct CameraTransformTests {
    private func assertNear(_ expected: Float, _ actual: Float, _ tolerance: Float = 0.001,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        near(expected, actual, tolerance, sourceLocation: sourceLocation)
    }

    @Test func fullPageContainFitCentersThePage() {
        // 1000x1500 page in a 500x500 container, fill = 1: height limits, scale = 1/3.
        let draw = computePageDraw(camera: .fullPage, bitmapW: 1000, bitmapH: 1500, containerW: 500, containerH: 500, fill: 1)
        assertNear(1000 / 3, draw.scaledWidth)
        assertNear(500, draw.scaledHeight)
        assertNear((500 - 1000 / 3) / 2, draw.left) // centered horizontally
        assertNear(0, draw.top)
    }

    @Test func panelRegionFillsContainerAndIsCentered() {
        // Left half of a square page in a square container: the camera region (500x1000 px)
        // is framed so its centre lands at the container centre.
        let camera = Panel(0, 0, 0.5, 1)
        let draw = computePageDraw(camera: camera, bitmapW: 1000, bitmapH: 1000, containerW: 400, containerH: 400, fill: 1)
        // Scale fits the 500x1000 region into 400x400 → 0.4; page becomes 400x400... scaled by
        // bitmap: scaledWidth = 1000*0.4 = 400.
        assertNear(400, draw.scaledWidth)
        assertNear(400, draw.scaledHeight)
        // Camera centre (250, 500) in bitmap px must map to container centre (200, 200).
        assertNear(200 - 250 * 0.4, draw.left)
        assertNear(200 - 500 * 0.4, draw.top)
    }

    @Test func fillFactorLeavesPadding() {
        let padded = computePageDraw(camera: .fullPage, bitmapW: 1000, bitmapH: 1000, containerW: 500, containerH: 500, fill: 0.9)
        assertNear(450, padded.scaledWidth)
        assertNear(450, padded.scaledHeight)
    }

    @Test func degenerateBitmapAndCameraSizesDoNotBlowUp() {
        let draw = computePageDraw(camera: Panel(0.5, 0.5, 0.5, 0.5), bitmapW: 0, bitmapH: 0, containerW: 100, containerH: 100)
        #expect(draw.scaledWidth.isFinite)
        #expect(draw.scaledHeight.isFinite)
        #expect(draw.left.isFinite)
        #expect(draw.top.isFinite)
    }
}
