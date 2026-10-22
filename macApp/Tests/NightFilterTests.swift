import XCTest
import SwiftUI
@testable import Chika

final class NightFilterTests: XCTestCase {
    // ⌥⌘N walks every filter and wraps back to off.
    func testNextCyclesThroughEveryFilterAndWraps() {
        XCTAssertEqual([NightFilter.off, .invert, .sepia, .dim].map(\.next), [.invert, .sepia, .dim, .off])
    }

    // Panels-mode dim covers the page around the camera and leaves the panel itself clear.
    func testOutsideCameraLeavesThePanelClear() {
        let page = CGRect(x: 0, y: 0, width: 200, height: 400)
        let path = OutsideCamera(camera: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)).path(in: page)
        XCTAssertFalse(path.contains(CGPoint(x: 150, y: 100), eoFill: true))   // the panel
        XCTAssertTrue(path.contains(CGPoint(x: 50, y: 100), eoFill: true))     // beside it
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 300), eoFill: true))    // below it
    }
}
