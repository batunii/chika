import Testing
import ChikaCore

struct PanelPipelineTests {
    @Test func pageWithNoDetectedPanelsIsBrokenUpNotShownWhole() {
        // When the model returns nothing, the whole page should still be split into zoom regions
        // (a portrait page is full-width + broad ⇒ a 2×2 quarter), never shown as a single panel.
        let regions = PanelPipeline.zoomRegions(panels: [], bubbles: [], pageW: 1000, pageH: 1500, rightToLeft: false)
        #expect(regions.count >= 2, "a page with no detections should be broken up; got \(regions)")
    }

    @Test func pipelineMatchesOrderingThenPlanning() {
        let shuffled = [
            Panel(0.55, 0.5, 1.0, 1.0),
            Panel(0.0, 0.0, 0.45, 0.4),
            Panel(0.0, 0.5, 0.45, 1.0),
            Panel(0.55, 0.0, 1.0, 0.4),
        ]
        let bubbles = [Panel(0.1, 0.1, 0.2, 0.2)]

        let viaPipeline = PanelPipeline.zoomRegions(panels: shuffled, bubbles: bubbles, pageW: 1000, pageH: 1500, rightToLeft: false)
        let manual = PanelPlanner.plan(
            ordered: PanelOrdering.order(shuffled, rightToLeft: false),
            bubbles: bubbles, pageW: 1000, pageH: 1500, rightToLeft: false
        )
        // The pipeline is ordering → planning → a small outward pad (breathing room for overflowing
        // text). So it must keep the same count and order, and each region must CONTAIN its planned
        // counterpart (padding only grows, clamped to the page) — never shrink or reorder.
        #expect(manual.count == viaPipeline.count, "pipeline should preserve the planned region count")
        for (i, (m, v)) in zip(manual, viaPipeline).enumerated() {
            #expect(
                v.left <= m.left + 1e-4 && v.top <= m.top + 1e-4 &&
                    v.right >= m.right - 1e-4 && v.bottom >= m.bottom - 1e-4,
                "pipeline region \(i) should be a padded superset of the planned region: \(v) vs \(m)"
            )
        }
    }
}
