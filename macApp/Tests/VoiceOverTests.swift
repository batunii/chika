import XCTest
import ChikaCore
@testable import Chika

@MainActor
final class VoiceOverTests: XCTestCase {
    private let english = Locale.Language(identifier: "en")
    // Two panels side by side; in the left one a balloon low and one high, in the right one a balloon.
    private let regions = [Panel(left: 0, top: 0, right: 0.5, bottom: 1), Panel(left: 0.5, top: 0, right: 1, bottom: 1)]
    private let low = Panel(left: 0.1, top: 0.6, right: 0.3, bottom: 0.8)
    private let high = Panel(left: 0.1, top: 0.1, right: 0.3, bottom: 0.3)
    private let right = Panel(left: 0.6, top: 0.1, right: 0.9, bottom: 0.3)

    private func balloon(_ box: Panel, _ original: String, translated: String? = nil) -> BalloonTranslator.Balloon {
        .init(box: box, original: original, language: nil, paper: .white, darkInk: true, translated: translated)
    }

    func testPageLabels() {
        XCTAssertEqual(PageAccessibility.label(pages: [3], of: 20, panel: (1, 5), hasText: true), "Page 4 of 20, panel 2 of 5")
        XCTAssertEqual(PageAccessibility.label(pages: [3], of: 20, panel: nil, hasText: nil), "Page 4 of 20")
        XCTAssertEqual(PageAccessibility.label(pages: [3, 4], of: 20, panel: nil, hasText: false), "Pages 4 and 5 of 20, no text")
    }

    func testAPanelsBalloonsInReadingOrderLabelledLikeReadAloud() {
        let read = [balloon(low, "Second"), balloon(right, "Other panel"), balloon(high, "今日は", translated: "Today"), balloon(.fullPage, "!?")]
        let panel = PageAccessibility.elements(read, step: 0, of: regions, rightToLeft: false, translate: true, target: english)
        XCTAssertEqual(panel.map(\.label), ["Today", "Second"])
        XCTAssertEqual(panel.first?.hint, "Original: 今日は")
        XCTAssertNil(panel.last?.hint)
        // Translate off: the text off the page.
        XCTAssertEqual(PageAccessibility.elements(read, step: 0, of: regions, rightToLeft: false, translate: false, target: english).first?.label, "今日は")
        // A whole page reads every balloon with letters panel by panel (the left panel's low one before the
        // right panel's high one), the right-hand panel first when reading right to left.
        XCTAssertEqual(PageAccessibility.elements(read, step: nil, of: regions, rightToLeft: false, translate: true, target: english)
                        .map(\.label), ["Today", "Second", "Other panel"])
        XCTAssertEqual(PageAccessibility.elements(read, step: nil, of: regions.reversed(), rightToLeft: true, translate: true, target: english)
                        .map(\.label), ["Other panel", "Today", "Second"])
        XCTAssertTrue(PageAccessibility.elements(read, step: 1, of: [regions[0]], rightToLeft: false, translate: true, target: english).isEmpty)
    }
}
