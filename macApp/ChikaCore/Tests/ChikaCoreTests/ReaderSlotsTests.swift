import Testing
import ChikaCore

struct ReaderSlotsTests {
    let six = (0..<6).map { i in Panel(0, Float(i) / 6, 1, Float(i + 1) / 6) }

    @Test func restoredOutroWithUnknownRegionsLandsOnOutroOnceDetected() {
        // The audit bug: a placeholder [fullPage] counted as one panel, so the outro resolved to step 1
        // and the next back-step landed on panel 2 of a page whose real panels were not known yet.
        var s = ReaderSlots(page: 1, step: ReaderSlots.outroSentinel)
        #expect(s.camera == .fullPage)
        s.setRegions(six)
        #expect(s.step == 6)
        #expect(s.camera == .fullPage)
        #expect(s.advance(by: -1, pageCount: 3) == .moved)
        #expect(s.step == 5 && s.camera == six[5]) // last panel, not panel 2
    }

    @Test func forwardFromIntroWithUnknownRegionsIsBlocked() {
        // Fast taps must wait for detection instead of skipping an undetected page.
        var s = ReaderSlots(page: 0, step: -1)
        #expect(s.advance(by: 1, pageCount: 3) == .blocked)
        #expect(s == ReaderSlots(page: 0, step: -1))
    }

    @Test func forwardPastOutroTurnsToNextPageIntro() {
        var s = ReaderSlots(page: 0, step: 6, regions: six)
        #expect(s.advance(by: 1, pageCount: 3) == .nextPage)
        #expect(s.page == 1 && s.step == -1 && s.regions == nil)
    }

    @Test func forwardPastOutroOnLastPageIsBlocked() {
        var s = ReaderSlots(page: 2, step: 6, regions: six)
        #expect(s.advance(by: 1, pageCount: 3) == .blocked)
        #expect(s.page == 2 && s.step == 6)
    }

    @Test func backFromIntroTurnsToPreviousPageOutro() {
        var known = ReaderSlots(page: 2, step: -1, regions: six)
        #expect(known.advance(by: -1, pageCount: 3) == .previousPage)
        #expect(known.page == 1 && known.step == ReaderSlots.outroSentinel && known.regions == nil)

        var unknown = ReaderSlots(page: 2, step: -1)
        #expect(unknown.advance(by: -1, pageCount: 3) == .previousPage)
        #expect(unknown.page == 1 && unknown.step == ReaderSlots.outroSentinel)

        var first = ReaderSlots(page: 0, step: -1)
        #expect(first.advance(by: -1, pageCount: 3) == .blocked)
    }

    @Test func unknownRegionsAllowLeavingTheOutroOnly() {
        var s = ReaderSlots(page: 1, step: ReaderSlots.outroSentinel)
        #expect(s.advance(by: -1, pageCount: 3) == .moved)
        #expect(s.step == -1)

        var forward = ReaderSlots(page: 1, step: ReaderSlots.outroSentinel)
        #expect(forward.advance(by: 1, pageCount: 3) == .nextPage)
        #expect(forward.page == 2 && forward.step == -1)

        var mid = ReaderSlots(page: 1, step: 2) // restored panel step, panels not detected yet
        #expect(mid.advance(by: -1, pageCount: 3) == .blocked)
        #expect(mid.camera == .fullPage)
    }

    @Test func stepsThroughPanelsAndShowWholePage() {
        var s = ReaderSlots(page: 0, step: -1, regions: six)
        #expect(s.advance(by: 1, pageCount: 3) == .moved)
        #expect(s.onPanel && s.camera == six[0])
        s.showWholePage()
        #expect(s.step == -1 && s.isFullPage)
    }
}
