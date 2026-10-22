import Testing
import ChikaCore

struct PanelEditingTests {
    private let a = Panel(0, 0, 0.5, 0.5), b = Panel(0.5, 0, 1, 0.5), c = Panel(0, 0.5, 1, 1)

    @Test func rectSpansTwoPointsInAnyOrderClampedToThePage() {
        #expect(PanelEditing.rect(0.6, 0.7, 0.2, 0.1) == Panel(0.2, 0.1, 0.6, 0.7))
        #expect(PanelEditing.rect(-0.3, 0.5, 1.4, 2) == Panel(0, 0.5, 1, 1))
    }

    @Test func aTinyRectGrowsTowardTheDragPointAndStaysOnThePage() {
        // Resizing from the bottom-right anchor (0.5, 0.5): the anchor keeps its place.
        let r = PanelEditing.rect(0.5, 0.5, 0.495, 0.5)
        near(0.48, r.left, 1e-5); near(0.5, r.right, 1e-5); near(0.5, r.top, 1e-5); near(0.52, r.bottom, 1e-5)
        let edge = PanelEditing.rect(1, 1, 1, 1)
        near(0.98, edge.left, 1e-5); near(1, edge.right, 1e-5); near(0.98, edge.top, 1e-5); near(1, edge.bottom, 1e-5)
    }

    @Test func movingKeepsTheSizeAndStopsAtThePageEdges() {
        #expect(PanelEditing.moved(a, dx: 0.25, dy: 0.1) == Panel(0.25, 0.1, 0.75, 0.6))
        #expect(PanelEditing.moved(a, dx: -0.2, dy: 0.9) == Panel(0, 0.5, 0.5, 1))
        #expect(PanelEditing.moved(.fullPage, dx: 0.3, dy: -0.3) == .fullPage)
    }

    @Test func mergeIsTheBoundingBoxAtTheEarliestIndex() {
        #expect(PanelEditing.merged([a, c, b], [2, 0]) == [Panel(0, 0, 1, 0.5), c])
        #expect(PanelEditing.merged([a, b, c], [1]) == [a, b, c])        // one panel: nothing to merge
        #expect(PanelEditing.merged([a, b], [0, 1, 7]) == [Panel(0, 0, 1, 0.5)])   // stale index ignored
    }

    @Test func splitMakesTwoHalvesInReadingOrder() {
        #expect(PanelEditing.split([a, c], at: 1, across: true, rightToLeft: false)
                == [a, Panel(0, 0.5, 1, 0.75), Panel(0, 0.75, 1, 1)])
        #expect(PanelEditing.split([c], at: 0, across: false, rightToLeft: false) == [Panel(0, 0.5, 0.5, 1), Panel(0.5, 0.5, 1, 1)])
        #expect(PanelEditing.split([c], at: 0, across: false, rightToLeft: true) == [Panel(0.5, 0.5, 1, 1), Panel(0, 0.5, 0.5, 1)])
        #expect(PanelEditing.split([Panel(0, 0, 0.03, 1)], at: 0, across: false, rightToLeft: false) == [Panel(0, 0, 0.03, 1)])
    }

    @Test func hitPicksTheSmallestPanelUnderThePoint() {
        let inner = Panel(0.1, 0.1, 0.3, 0.3)
        #expect(PanelEditing.hit([a, inner, c], x: 0.2, y: 0.2) == 1)
        #expect(PanelEditing.hit([a, inner, c], x: 0.4, y: 0.4) == 0)
        #expect(PanelEditing.hit([a, inner, c], x: 0.2, y: 0.2, among: [0, 2]) == 0)
        #expect(PanelEditing.hit([a, inner], x: 0.7, y: 0.2) == nil)
    }

    @Test func reorderMovesOnePlaceAndStopsAtTheEnds() {
        #expect(PanelEditing.reordered([a, b, c], moving: 2, by: -1) == [a, c, b])
        #expect(PanelEditing.reordered([a, b, c], moving: 0, by: 1) == [b, a, c])
        #expect(PanelEditing.reordered([a, b, c], moving: 0, by: -1) == [a, b, c])
        #expect(PanelEditing.reordered([a, b, c], moving: 2, by: 1) == [a, b, c])
    }
}
