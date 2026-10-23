import Testing
import ChikaCore

struct SwipeTurnTests {
    @Test func swipingLeftReadsOnLeftToRightAndBackRightToLeft() {
        var swipe = SwipeTurn()
        #expect(swipe.moved(dx: -40, dy: 0, rightToLeft: false) == nil)   // not far enough yet
        #expect(swipe.moved(dx: -30, dy: 5, rightToLeft: false) == true)
        swipe.begin()
        #expect(swipe.moved(dx: -70, dy: 0, rightToLeft: true) == false)
        swipe.begin()
        #expect(swipe.moved(dx: 70, dy: 0, rightToLeft: true) == true)
        swipe.begin()
        #expect(swipe.moved(dx: 70, dy: 0, rightToLeft: false) == false)
    }

    @Test func turnsOncePerGesture() {
        var swipe = SwipeTurn()
        #expect(swipe.moved(dx: -80, dy: 0, rightToLeft: false) == true)
        #expect(swipe.moved(dx: -200, dy: 0, rightToLeft: false) == nil)
        #expect(swipe.moved(dx: 400, dy: 0, rightToLeft: false) == nil)   // swinging back does nothing either
        swipe.begin()
        #expect(swipe.moved(dx: 80, dy: 0, rightToLeft: false) == false)
    }

    @Test func mostlyVerticalNeverTurns() {
        var swipe = SwipeTurn()
        #expect(swipe.moved(dx: -70, dy: 40, rightToLeft: false) == nil)
        #expect(swipe.moved(dx: -10, dy: 200, rightToLeft: false) == nil)
    }
}
