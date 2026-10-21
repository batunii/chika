import Testing
import ChikaCore

struct PanelOrderingTests {
    let topLeft = Panel(0.0, 0.0, 0.45, 0.4)
    let topRight = Panel(0.55, 0.0, 1.0, 0.4)
    let bottomLeft = Panel(0.0, 0.5, 0.45, 1.0)
    let bottomRight = Panel(0.55, 0.5, 1.0, 1.0)

    @Test func ordersRowsTopDownThenLeftToRight() {
        let shuffled = [bottomRight, topRight, bottomLeft, topLeft]
        #expect(PanelOrdering.order(shuffled) == [topLeft, topRight, bottomLeft, bottomRight])
    }

    @Test func rightToLeftReversesWithinRowsOnly() {
        let shuffled = [bottomRight, topRight, bottomLeft, topLeft]
        #expect(PanelOrdering.order(shuffled, rightToLeft: true) == [topRight, topLeft, bottomRight, bottomLeft])
    }

    @Test func slightlyMisalignedPanelsStillShareARow() {
        // Vertical ranges overlap well over half of the shorter panel's height.
        let left = Panel(0.0, 0.10, 0.45, 0.45)
        let right = Panel(0.55, 0.05, 1.0, 0.40)
        #expect(PanelOrdering.order([right, left]) == [left, right])
    }

    @Test func barelyOverlappingPanelsFormSeparateRows() {
        // Overlap is far below half of the shorter panel's height → two rows, top first.
        let upper = Panel(0.5, 0.0, 1.0, 0.32)
        let lower = Panel(0.0, 0.3, 0.45, 0.7)
        #expect(PanelOrdering.order([lower, upper]) == [upper, lower])
    }

    @Test func staggeredBottomRowUnderAnOverlappingPanelReadsLeftToRight() {
        // Page-57 shape: a huge panel overlaps everything (no clean cut), with a bottom row whose two
        // panels are vertically staggered. The bottom row must read left→right, not "higher-first".
        let huge = Panel(0.0, 0.01, 1.0, 0.84)
        let bottomRightHigher = Panel(0.48, 0.77, 0.89, 0.98) // starts higher
        let bottomLeftLower = Panel(0.0, 0.84, 0.48, 1.0)     // starts lower, but is on the left
        #expect(PanelOrdering.order([bottomRightHigher, huge, bottomLeftLower]) == [huge, bottomLeftLower, bottomRightHigher])
    }

    @Test func emptyAndSingleListsPassThrough() {
        #expect(PanelOrdering.order([]) == [])
        #expect(PanelOrdering.order([topLeft]) == [topLeft])
    }
}
