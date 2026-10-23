/// The full shared post-detection pipeline in one call: raw detected boxes go in, final zoom
/// regions in reading order come out. Platform readers (Android ViewModel, Apple apps) should call
/// this rather than composing `PanelOrdering` and `PanelPlanner` themselves so both stay in sync.
public enum PanelPipeline {
    /// Each framed panel is grown by this fraction of its own size on every side, so the reader shows
    /// a little context around it instead of hugging the detected box edge-to-edge. Detected boxes run
    /// tight and clip overflowing speech bubbles / furigana / SFX; this breathing room brings them back
    /// into frame. At the reader's `fill = 0.98` framing, ~5.7% per side leaves the *original* panel
    /// filling ~88% of the screen (a ~12% gap). Only real panels are padded — the whole-page intro/outro
    /// slots the reader synthesizes aren't in this list, so they still fill the screen.
    private static let panelMargin: Float = 0.057

    public static func zoomRegions(
        panels: [Panel],
        bubbles: [Panel],
        pageW: Int,
        pageH: Int,
        rightToLeft: Bool
    ) -> [Panel] {
        // Add any large, roughly-rectangular region the model left uncovered as a panel, so missed
        // panels get numbered too — then order and plan as usual.
        // Manga (read right-to-left) is paced panel-by-panel, so it uses a profile that merges far
        // less aggressively; Western LTR comics keep the default grid-friendly merging.
        let config = rightToLeft ? PanelPlanner.Config.manga : PanelPlanner.Config()
        let filled = PanelGapFiller.fill(panels)
        let ordered = PanelOrdering.order(filled, rightToLeft: rightToLeft)
        let planned = PanelPlanner.plan(ordered: ordered, bubbles: bubbles, pageW: pageW, pageH: pageH,
                                        rightToLeft: rightToLeft, config: config)
        if planned.count >= 2 { return pad(planned) }
        // The model found nothing usable (or it collapsed to a single region): rather than show the
        // page as one panel, treat the whole page as a panel and let the ratio splitter break it up.
        return pad(PanelPlanner.plan(ordered: [.fullPage], bubbles: bubbles, pageW: pageW, pageH: pageH,
                                     rightToLeft: rightToLeft, config: config))
    }

    /// Grows each panel by `panelMargin` of its own size per side, clamped to the page.
    private static func pad(_ panels: [Panel]) -> [Panel] {
        panels.map { p in
            let dx = p.width * panelMargin
            let dy = p.height * panelMargin
            return Panel(
                left: max(p.left - dx, 0),
                top: max(p.top - dy, 0),
                right: min(p.right + dx, 1),
                bottom: min(p.bottom + dy, 1)
            )
        }
    }
}

/// One page's detector output as the reader keeps it: the zoom regions for each reading direction
/// (planning is cheap next to inference, so one model run plans both) and the raw speech-balloon boxes.
public struct PageDetection: Equatable, Sendable {
    public let leftToRight: [Panel]
    public let rightToLeft: [Panel]
    public let bubbles: [Panel]

    public init(leftToRight: [Panel], rightToLeft: [Panel], bubbles: [Panel]) {
        self.leftToRight = leftToRight
        self.rightToLeft = rightToLeft
        self.bubbles = bubbles
    }

    /// Plans `result` in both directions. Fewer than 2 regions read the page whole, as Android's
    /// MlPanelDetector.detect does.
    public init(_ result: DetectResult) {
        let plan = { (rtl: Bool) -> [Panel] in
            let planned = PanelPipeline.zoomRegions(panels: result.panels, bubbles: result.bubbles,
                                                    pageW: result.pageW, pageH: result.pageH, rightToLeft: rtl)
            return planned.count < 2 ? [.fullPage] : planned
        }
        self.init(leftToRight: plan(false), rightToLeft: plan(true), bubbles: result.bubbles)
    }

    public func regions(rightToLeft rtl: Bool) -> [Panel] { rtl ? rightToLeft : leftToRight }
}
