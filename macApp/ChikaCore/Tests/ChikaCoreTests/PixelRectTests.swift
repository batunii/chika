import Testing
import ChikaCore

struct PixelRectTests {
    private func rect(_ panel: Panel, _ w: Int, _ h: Int) -> [Int] {
        let r = panel.pixelRect(width: w, height: h)
        return [r.x, r.y, r.width, r.height]
    }

    @Test func mapsNormalizedEdgesToPixels() {
        #expect(rect(Panel(0.25, 0.25, 0.75, 0.5), 1000, 800) == [250, 200, 500, 200])
        #expect(rect(.fullPage, 1000, 800) == [0, 0, 1000, 800])
    }

    @Test func roundsOutwardSoNoEdgeIsCut() {
        // 250.5 → 250 on the left, 749.5 → 750 on the right.
        #expect(rect(Panel(0.2505, 0, 0.7495, 1), 1000, 10) == [250, 0, 500, 10])
    }

    @Test func clampsToTheImageAndNeverComesBackEmpty() {
        #expect(rect(Panel(-0.1, -0.1, 1.2, 1.2), 100, 50) == [0, 0, 100, 50])
        #expect(rect(Panel(0.5, 0.5, 0.5, 0.5), 100, 100) == [50, 50, 1, 1])
        #expect(rect(Panel(1, 1, 1, 1), 100, 100) == [99, 99, 1, 1])
    }
}
