import Testing
import ChikaCore

struct SpreadsTests {
    @Test func coverStandsAloneThenFacingPagesPair() {
        #expect(Spreads.pairs(pageCount: 6) == [[0], [1, 2], [3, 4], [5]])
        #expect(Spreads.pairs(pageCount: 5) == [[0], [1, 2], [3, 4]])
        #expect(Spreads.pairs(pageCount: 1) == [[0]])
        #expect(Spreads.pairs(pageCount: 0).isEmpty)
    }

    @Test func aWidePageStandsAloneAndSoDoesThePageBeforeIt() {
        // Page 4 is a scanned double page: page 3 can't face it, so both stand alone.
        #expect(Spreads.pairs(pageCount: 8, wide: [4]) == [[0], [1, 2], [3], [4], [5, 6], [7]])
    }

    @Test func findsTheSpreadForAnyPage() {
        #expect(Spreads.spread(containing: 2, pageCount: 6) == [1, 2])
        #expect(Spreads.spread(containing: 0, pageCount: 6) == [0])
        #expect(Spreads.spread(containing: 4, pageCount: 8, wide: [4]) == [4])
        #expect(Spreads.spread(containing: 9, pageCount: 6) == [9])   // out of range: itself
    }
}
