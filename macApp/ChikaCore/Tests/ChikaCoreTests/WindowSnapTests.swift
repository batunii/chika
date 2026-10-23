import CoreGraphics
import Testing
import ChikaCore

struct WindowSnapTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func dropsNearACornerSnapIntoIt() {
        // 30 pt from the top-right snapped place on both axes.
        let frame = CGRect(x: 1440 - 16 - 420 - 30, y: 900 - 16 - 300 - 20, width: 420, height: 300)
        #expect(WindowSnap.corner(near: frame, in: screen) == .topRight)
        #expect(WindowSnap.origin(.topRight, size: frame.size, in: screen) == CGPoint(x: 1004, y: 584))
        // Pushed partly past the bottom-left edges still counts.
        let past = CGRect(x: -10, y: 5, width: 420, height: 300)
        #expect(WindowSnap.corner(near: past, in: screen) == .bottomLeft)
        #expect(WindowSnap.origin(.bottomLeft, size: past.size, in: screen) == CGPoint(x: 16, y: 16))
    }

    @Test func farFromEveryCornerStaysPut() {
        #expect(WindowSnap.corner(near: CGRect(x: 500, y: 300, width: 420, height: 300), in: screen) == nil)
        // Near the left edge but halfway down: an edge is not a corner.
        #expect(WindowSnap.corner(near: CGRect(x: 16, y: 300, width: 420, height: 300), in: screen) == nil)
    }

    @Test func worksOnAScreenNotAtTheOrigin() {
        let second = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let frame = CGRect(x: 1440 + 16, y: -200 + 1080 - 16 - 300, width: 420, height: 300)
        #expect(WindowSnap.corner(near: frame, in: second) == .topLeft)
    }

    @Test func reopensInItsCornerOrAtItsTopLeft() {
        let cornered = CGRect(origin: WindowSnap.origin(.topRight, size: CGSize(width: 420, height: 300), in: screen),
                              size: CGSize(width: 420, height: 300))
        // A new panel shape: still flush in the top-right corner.
        #expect(WindowSnap.restore(cornered, size: CGSize(width: 420, height: 600), in: screen) == CGPoint(x: 1004, y: 284))
        let loose = CGRect(x: 500, y: 300, width: 420, height: 300)
        #expect(WindowSnap.restore(loose, size: CGSize(width: 420, height: 200), in: screen) == CGPoint(x: 500, y: 400))
        #expect(WindowSnap.restore(CGRect(x: 3000, y: 0, width: 420, height: 300), size: loose.size, in: screen) == nil)
    }
}
