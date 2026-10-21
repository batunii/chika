import Testing
import ChikaCore

struct PanelGapFillerTests {
    @Test func emptyInputIsUnchanged() {
        #expect(PanelGapFiller.fill([]) == [])
    }

    @Test func bigRectangularLeftoverBecomesAPanel() throws {
        // One panel covers the top 40%; the bottom 60% is a missed panel.
        let top = Panel(0.0, 0.0, 1.0, 0.40)
        let result = PanelGapFiller.fill([top])
        try #require(result.count == 2)
        let gap = result[result.count - 1]
        #expect((0.35...0.45).contains(gap.top), "gap top=\(gap)")
        #expect(gap.bottom >= 0.95, "gap bottom=\(gap)")
        #expect(gap.width >= 0.95, "gap width=\(gap)")
    }

    @Test func missedPanelSurroundedByMarginsIsStillRecovered() throws {
        // The realistic case: panels don't reach the page edges, so a margin frame surrounds and
        // connects every uncovered cell. A detected panel sits in the top ~45%; the bottom panel is
        // missed. The largest empty rectangle must isolate the missed bottom region despite margins.
        let detectedTop = Panel(0.04, 0.04, 0.96, 0.46)
        let result = PanelGapFiller.fill([detectedTop])
        try #require(result.count == 2)
        let gap = result[result.count - 1]
        #expect((0.40...0.55).contains(gap.top), "gap top=\(gap)")
        #expect(gap.bottom >= 0.95, "gap bottom=\(gap)")
        #expect(gap.width >= 0.90, "gap width=\(gap)")
    }

    @Test func smallLeftoverBelowThresholdIsIgnored() {
        // Only a ~3% strip at the bottom is uncovered — below the area threshold.
        let p = Panel(0.0, 0.0, 1.0, 0.97)
        #expect(PanelGapFiller.fill([p]).count == 1)
    }

    @Test func thinMarginFrameIsIgnored() {
        // A centred panel with realistic ~4% margins: every leftover strip is too thin to be a panel.
        let center = Panel(0.04, 0.04, 0.96, 0.96)
        #expect(PanelGapFiller.fill([center]).count == 1)
    }

    @Test func missedPanelIsNumberedByThePipeline() throws {
        // Top panel + a big uncovered bottom: the pipeline should yield at least 2 regions in order.
        let top = Panel(0.0, 0.0, 1.0, 0.35)
        let regions = PanelPipeline.zoomRegions(panels: [top], bubbles: [], pageW: 1000, pageH: 1500, rightToLeft: false)
        try #require(regions.count >= 2, "expected the gap to be added; got \(regions)")
        // Reading order: the top region comes before the filled bottom one.
        #expect(regions[0].top <= regions[regions.count - 1].top)
    }
}
