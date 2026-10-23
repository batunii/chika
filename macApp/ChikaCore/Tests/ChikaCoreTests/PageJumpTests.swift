import Testing
import ChikaCore

struct PageJumpTests {
    @Test func digitsGatherUpToThePageCountsLength() {
        var typed = ""
        for digit in "12" { typed = PageJump.append(digit, to: typed, pageCount: 120) }
        #expect(typed == "12")
        typed = PageJump.append("5", to: typed, pageCount: 120)
        #expect(typed == "125")
        #expect(PageJump.append("7", to: typed, pageCount: 120) == "7")   // a fourth digit starts over
        #expect(PageJump.append("3", to: "4", pageCount: 9) == "3")
    }

    @Test func namesAOneBasedPageClampedToTheComic() {
        #expect(PageJump.page("12", pageCount: 120) == 11)
        #expect(PageJump.page("1", pageCount: 120) == 0)
        #expect(PageJump.page("0", pageCount: 120) == 0)
        #expect(PageJump.page("125", pageCount: 120) == 119)
        #expect(PageJump.page("", pageCount: 120) == nil)
        #expect(PageJump.page("3", pageCount: 0) == nil)
    }

    @Test func aScrubberStepGoesToItsPageOrTheSpreadBefore() {
        #expect(PageJump.scrubbed(to: 4.2, visible: [3]) == 4)
        #expect(PageJump.scrubbed(to: 3.4, visible: [3]) == nil)   // not a page away yet
        #expect(PageJump.scrubbed(to: 9, visible: [6, 7]) == 9)
        #expect(PageJump.scrubbed(to: 6, visible: [6, 7]) == 5)    // back a spread, not onto the one on screen
        #expect(PageJump.scrubbed(to: 7, visible: [6, 7]) == nil)
        #expect(PageJump.scrubbed(to: 0, visible: [0, 1]) == nil)  // nothing before the first
        #expect(PageJump.scrubbed(to: 2, visible: []) == nil)
    }
}
