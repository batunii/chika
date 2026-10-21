import Testing
import ChikaCore

/// Regression pin from the July 2026 iOS framing investigation: the raw detections for Vinland
/// Saga v01 p159 (a 7-panel RTL page whose first panel is the tall top-right "woman behind the
/// curtain") must plan into 7 regions whose first camera nearly fills a phone screen. The on-device
/// render was observed diverging from this exact math, so this test pins what the shared pipeline
/// *should* hand every platform for that page.
struct DevicePageDiagnosticTests {
    @Test func v01p159PlansSevenRegionsAndPanel1FillsAPhoneScreen() throws {
        let pageW = 3412
        let pageH = 4800
        let panels = [
            Panel(0.5869, 0.6130, 0.8878, 0.7897),
            Panel(0.0010, 0.4301, 0.5726, 0.7672),
            Panel(0.0015, 0.0004, 0.6271, 0.4155),
            Panel(0.6374, 0.0005, 0.8879, 0.4146),
            Panel(0.5857, 0.8015, 0.8900, 0.9998),
            Panel(0.0016, 0.7829, 0.5729, 1.0000),
            Panel(0.5839, 0.4286, 0.8882, 0.5984),
        ]
        let bubbles = [
            Panel(0.4279, 0.8062, 0.5558, 0.9271),
            Panel(0.0991, 0.0970, 0.2187, 0.1784),
            Panel(0.3831, 0.0950, 0.4623, 0.1481),
            Panel(0.1765, 0.7897, 0.2379, 0.8718),
            Panel(0.6528, 0.3102, 0.7328, 0.4064),
            Panel(0.0738, 0.2309, 0.1376, 0.2454),
            Panel(0.6560, 0.8147, 0.6728, 0.8363),
        ]
        let planned = PanelPipeline.zoomRegions(panels: panels, bubbles: bubbles, pageW: pageW, pageH: pageH, rightToLeft: true)
        try #require(planned.count == 7)

        // First region in RTL order is the padded tall top-right panel.
        let first = planned[0]
        #expect(abs(first.left - 0.6231) < 0.01, "region 1 left drifted: \(first.left)")
        #expect(first.top == 0, "region 1 top should clamp to the page top: \(first.top)")
        #expect(abs(first.right - 0.9022) < 0.01, "region 1 right drifted: \(first.right)")
        #expect(abs(first.bottom - 0.4382) < 0.01, "region 1 bottom drifted: \(first.bottom)")

        // Framed on an iPhone 12/13 Pro Max screen the panel nearly fills it: the page draws with
        // its top just below the screen top, not floating a third of the way down.
        let draw = computePageDraw(camera: first, bitmapW: pageW, bitmapH: pageH, containerW: 428, containerH: 926, fill: 0.98)
        #expect((0...20).contains(draw.top), "page top should sit near the screen top, was \(draw.top)")
        let panelLeftOnScreen = draw.left + 0.6374 * draw.scaledWidth
        let panelRightOnScreen = draw.left + 0.8879 * draw.scaledWidth
        let widthFraction = (panelRightOnScreen - panelLeftOnScreen) / 428
        #expect(widthFraction > 0.8, "panel should fill most of the width, filled \(widthFraction)")
    }
}
