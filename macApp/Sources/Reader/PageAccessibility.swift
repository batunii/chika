import SwiftUI
import ChikaCore

/// VoiceOver on the reader's page: its position as the page's label, and the speech balloons of the
/// view on screen as elements in reading order, read from Translate's recognized text.
enum PageAccessibility {
    struct Element: Identifiable {
        let box: Panel
        let label: String
        let hint: String?
        var id: Panel { box }
    }

    static let hint = "Use the left and right arrow keys to read on or go back."

    /// "Page 4 of 20, panel 2 of 5" or "Pages 4 and 5 of 20" (`pages` 0-based), then ", no text" when
    /// the view's text has been read and it has none (`hasText` nil: not read yet).
    static func label(pages: [Int], of count: Int, panel: (step: Int, count: Int)?, hasText: Bool?) -> String {
        let numbers = pages.map { "\($0 + 1)" }.joined(separator: " and ")
        var label = "Page\(pages.count > 1 ? "s" : "") \(numbers) of \(count)"
        if let panel { label += ", panel \(panel.step + 1) of \(panel.count)" }
        if hasText == false { label += ", no text" }
        return label
    }

    /// A page's balloons in the view on screen, in reading order: the panel `step` of `regions` (each
    /// balloon belongs to one panel, as for Read aloud), every balloon when `step` is nil (a whole page).
    /// Labelled like Read aloud speaks them: the translation when Translate is on and has one, else the
    /// text off the page; balloons without letters are left out.
    @MainActor static func elements(_ read: [BalloonTranslator.Balloon], step: Int?, of regions: [Panel], rightToLeft: Bool,
                                    translate: Bool, target: Locale.Language) -> [Element] {
        let boxes = BalloonText.balloons(read.map(\.box), inRegion: step ?? 0, of: step == nil ? [.fullPage] : regions,
                                         rightToLeft: rightToLeft)
        return boxes.compactMap { box in
            guard let balloon = read.first(where: { $0.box == box }),
                  let line = BalloonSpeaker.line(balloon, page: 0, translate: translate, target: target) else { return nil }
            return Element(box: box, label: line.text, hint: line.text == balloon.original ? nil : "Original: \(balloon.original)")
        }
    }
}

/// The balloons' VoiceOver elements over one page, in the page's own coordinates (inside its transform,
/// like Translate's labels), invisible and never in the way of clicks.
struct BalloonAccessibility: View {
    let elements: [PageAccessibility.Element]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(elements.enumerated()), id: \.element.id) { i, element in
                Color.clear
                    .frame(width: CGFloat(element.box.width) * geo.size.width, height: CGFloat(element.box.height) * geo.size.height)
                    .position(x: CGFloat(element.box.centerX) * geo.size.width, y: CGFloat(element.box.centerY) * geo.size.height)
                    .accessibilityElement()
                    .accessibilityLabel(element.label)
                    .accessibilityHint(element.hint ?? "")
                    .accessibilitySortPriority(Double(elements.count - i))   // reading order, not screen order
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }
}
