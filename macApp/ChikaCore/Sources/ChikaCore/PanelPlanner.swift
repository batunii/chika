/// Post-processes the ML model's panels into a nicer set of zoom regions:
///
///  - **Merge** runs of panels that are both *consecutive in reading order* and *spatially adjacent*
///    when they're individually too small — so a strip of tiny panels becomes one comfortable zoom.
///  - **Divide** oversized panels, using the panel's size *relative to the page*:
///      - A panel **as wide as the page** but not tall → split into **2** side-by-side pieces.
///      - A panel **as wide as the page and tall ("broad")** → split into **4** (a 2×2 grid).
///      - A **double-page spread** (landscape image) with a panel spanning both pages → split at the
///        page seam into two halves, then apply the 2/4 rule to each half → **up to 8** pieces.
///      - Other big elongated panels keep the classic single cut (wide → vertical, tall → horizontal).
///      - Square / normal panels are left as-is.
///    Cuts are placed in the gap between speech-bubble groups when bubbles are available, else centred.
///
/// Works in normalized `[0,1]` coordinates; real pixel aspect uses the page dimensions, since a
/// normalized square isn't a real square on a non-square page.
public enum PanelPlanner {

    public struct Config: Sendable {
        /// Panel area (fraction of page) below which it's "small" → a merge candidate.
        public var smallAreaFraction: Float
        /// Panel area (fraction of page) above which it's "big" → a divide candidate.
        public var bigAreaFraction: Float
        /// Pixel aspect (w/h) within [low, high] counts as square → never divided (when not full-width).
        public var squareAspectLow: Float
        public var squareAspectHigh: Float
        /// Max normalized gap between two panels for them to count as adjacent.
        public var adjacencyGap: Float
        /// Min perpendicular overlap (fraction of the shorter side) for adjacency.
        public var adjacencyOverlap: Float
        /// Hard cap on how many small panels merge into one zoom (readability).
        public var maxMergeCount: Int
        /// A merged group may not exceed these fractions of the page (keeps the zoom readable).
        public var maxMergedWidthFraction: Float
        public var maxMergedHeightFraction: Float
        /// A divide cut must fall within this central band of the panel (avoids lopsided cuts).
        public var cutCentralMin: Float
        public var cutCentralMax: Float
        // --- ratio-based division ---
        /// Panel width ≥ this fraction of the page ⇒ "as wide as the page".
        public var fullWidthFraction: Float
        /// Panel height ≥ this fraction of the page ⇒ "broad" (split into 4 rather than 2).
        public var broadHeightFraction: Float
        /// Don't split a full-width panel thinner than this (avoids slicing thin banners).
        public var minDivideHeightFraction: Float
        /// Image aspect (w/h) ≥ this ⇒ treat the page image as a double-page spread. Two portrait
        /// pages side by side give ≈1.3 (2× a ~0.65 single-page aspect), so the cutoff sits below
        /// that — anything clearly wider than tall is a spread.
        public var spreadAspectMin: Float
        /// On a spread, a panel this wide (fraction of the image) is treated as spanning both pages.
        public var crossPageWidthFraction: Float
        /// On a spread, a panel at least this wide (≈ one page-half) is "full width of its own page",
        /// so a big per-page panel on a wide spread is broken into more parts instead of left whole.
        public var spreadPageWidthFraction: Float

        public init(
            smallAreaFraction: Float = 0.10,
            bigAreaFraction: Float = 0.35,
            squareAspectLow: Float = 0.8,
            squareAspectHigh: Float = 1.25,
            adjacencyGap: Float = 0.05,
            adjacencyOverlap: Float = 0.4,
            maxMergeCount: Int = 3,
            maxMergedWidthFraction: Float = 0.55,
            maxMergedHeightFraction: Float = 0.45,
            cutCentralMin: Float = 0.30,
            cutCentralMax: Float = 0.70,
            fullWidthFraction: Float = 0.85,
            broadHeightFraction: Float = 0.55,
            minDivideHeightFraction: Float = 0.10,
            spreadAspectMin: Float = 1.15,
            crossPageWidthFraction: Float = 0.85,
            spreadPageWidthFraction: Float = 0.42
        ) {
            self.smallAreaFraction = smallAreaFraction
            self.bigAreaFraction = bigAreaFraction
            self.squareAspectLow = squareAspectLow
            self.squareAspectHigh = squareAspectHigh
            self.adjacencyGap = adjacencyGap
            self.adjacencyOverlap = adjacencyOverlap
            self.maxMergeCount = maxMergeCount
            self.maxMergedWidthFraction = maxMergedWidthFraction
            self.maxMergedHeightFraction = maxMergedHeightFraction
            self.cutCentralMin = cutCentralMin
            self.cutCentralMax = cutCentralMax
            self.fullWidthFraction = fullWidthFraction
            self.broadHeightFraction = broadHeightFraction
            self.minDivideHeightFraction = minDivideHeightFraction
            self.spreadAspectMin = spreadAspectMin
            self.crossPageWidthFraction = crossPageWidthFraction
            self.spreadPageWidthFraction = spreadPageWidthFraction
        }

        /// Manga profile: manga is paced panel-by-panel — small reaction/dialogue beats are
        /// narratively distinct, and the reader wants to land on each rather than have a strip of
        /// them merged into one zoom. So only *truly tiny* panels merge, and at most two at a time
        /// (vs. the Western-comic default that fuses runs of up to three ~10%-of-page panels).
        /// Division of oversized/spread panels is unchanged — a wide panel on a phone still splits.
        public static let manga = Config(smallAreaFraction: 0.05, maxMergeCount: 2)
    }

    private struct Region { let panel: Panel; let merged: Bool }

    /// Direction a merge run is growing in, so a group stays a single row or column (no L-shapes).
    private enum Dir { case none, horizontal, vertical }

    public static func plan(
        ordered: [Panel],
        bubbles: [Panel],
        pageW: Int,
        pageH: Int,
        rightToLeft: Bool,
        config: Config = Config()
    ) -> [Panel] {
        if ordered.isEmpty { return ordered }
        let pageAspect = Float(pageW) / Float(pageH)

        let merged = mergeSmall(ordered, config)
        var result: [Panel] = []
        result.reserveCapacity(merged.count)
        for region in merged {
            let p = region.panel
            if !region.merged && shouldDivide(p, pageAspect, config) {
                result += divide(p, bubbles, pageAspect, rightToLeft, config)
            } else {
                result.append(p)
            }
        }
        return result
    }

    private static func mergeSmall(_ ordered: [Panel], _ config: Config) -> [Region] {
        var regions: [Region] = []
        var i = 0
        while i < ordered.count {
            let cur = ordered[i]
            if !isSmall(cur, config) {
                regions.append(Region(panel: cur, merged: false))
                i += 1
                continue
            }
            var union = cur
            var j = i
            var count = 1
            var dir = Dir.none
            while j + 1 < ordered.count && count < config.maxMergeCount && isSmall(ordered[j + 1], config) {
                let next = ordered[j + 1]
                let stepDir = adjacencyDir(ordered[j], next, config)
                if stepDir == .none { break }
                if dir == .none { dir = stepDir } else if stepDir != dir { break }
                let candidate = Self.union(union, next)
                if candidate.width > config.maxMergedWidthFraction ||
                    candidate.height > config.maxMergedHeightFraction
                { break }
                union = candidate
                j += 1
                count += 1
            }
            regions.append(Region(panel: union, merged: count > 1))
            i = j + 1
        }
        return regions
    }

    /// Whether a (non-merged) panel should be split, and which rule applies, is decided here.
    private static func shouldDivide(_ p: Panel, _ pageAspect: Float, _ c: Config) -> Bool {
        let spread = isSpread(pageAspect, c)
        if spread && isCrossPage(p, c) { return true }
        if isFullWidth(p, c, spread) && p.height >= c.minDivideHeightFraction { return true }
        return isBig(p, c) && !isSquare(p, pageAspect, c)
    }

    private static func divide(
        _ panel: Panel,
        _ bubbles: [Panel],
        _ pageAspect: Float,
        _ rightToLeft: Bool,
        _ config: Config
    ) -> [Panel] {
        // Double-page spread: the two pages are one merged image, so a panel spanning them is read
        // row by row across the full width — a piece on the left page and one at the same height on
        // the right page are consecutive, NOT "whole right page then whole left page". Split into a
        // 4-column grid (≈2 columns per page), with a second row when it's also tall, emitted in
        // reading order (top→bottom, each row left→right or right→left).
        if isSpread(pageAspect, config) && isCrossPage(panel, config) {
            let rows = panel.height >= config.broadHeightFraction ? 2 : 1
            return gridSplit(panel, cols: 4, rows: rows, rightToLeft)
        }
        // A panel as wide as the page (or, on a spread, as wide as one page) → 2 (just wide) or 4 (broad).
        if isFullWidth(panel, config, isSpread(pageAspect, config)) {
            return splitByBreadth(panel, bubbles, rightToLeft, config)
        }
        // Other big, elongated, non-square panels keep the classic single cut.
        return classicDivide(panel, bubbles, pageAspect, rightToLeft, config)
    }

    /// Splits `panel` into a `rows`×`cols` grid with even cuts, emitted row by row (top→bottom) and
    /// within each row in reading direction (left→right, or right→left for `rtl`). Used for a wide
    /// spread panel so the merged two pages read as one across the seam.
    private static func gridSplit(_ panel: Panel, cols: Int, rows: Int, _ rtl: Bool) -> [Panel] {
        let cw = panel.width / Float(cols)
        let rh = panel.height / Float(rows)
        var pieces: [Panel] = []
        pieces.reserveCapacity(rows * cols)
        for r in 0..<rows {
            let top = r == 0 ? panel.top : panel.top + Float(r) * rh
            let bottom = r == rows - 1 ? panel.bottom : panel.top + Float(r + 1) * rh
            let colOrder = rtl ? Array((0..<cols).reversed()) : Array(0..<cols)
            for c in colOrder {
                let left = c == 0 ? panel.left : panel.left + Float(c) * cw
                let right = c == cols - 1 ? panel.right : panel.left + Float(c + 1) * cw
                pieces.append(Panel(left: left, top: top, right: right, bottom: bottom))
            }
        }
        return pieces
    }

    /// Full-width region → 4 pieces (2×2) if broad (tall too), else 2 pieces (side-by-side).
    private static func splitByBreadth(_ panel: Panel, _ bubbles: [Panel], _ rtl: Bool, _ config: Config) -> [Panel] {
        let inside = bubblesInside(panel, bubbles)
        return panel.height >= config.broadHeightFraction
            ? quarter(panel, inside, rtl, config)
            : halveLeftRight(panel, inside, rtl, config)
    }

    /// Two side-by-side pieces (one vertical, bubble-aware cut).
    private static func halveLeftRight(_ panel: Panel, _ inside: [Panel], _ rtl: Bool, _ config: Config) -> [Panel] {
        let cut = cutPosition(inside.map(\.left), inside.map(\.right), panel.left, panel.right, config)
        let left = Panel(left: panel.left, top: panel.top, right: cut, bottom: panel.bottom)
        let right = Panel(left: cut, top: panel.top, right: panel.right, bottom: panel.bottom)
        return rtl ? [right, left] : [left, right]
    }

    /// Four pieces in a 2×2 grid (one vertical + one horizontal, bubble-aware cut).
    private static func quarter(_ panel: Panel, _ inside: [Panel], _ rtl: Bool, _ config: Config) -> [Panel] {
        let vCut = cutPosition(inside.map(\.left), inside.map(\.right), panel.left, panel.right, config)
        let hCut = cutPosition(inside.map(\.top), inside.map(\.bottom), panel.top, panel.bottom, config)
        let tl = Panel(left: panel.left, top: panel.top, right: vCut, bottom: hCut)
        let tr = Panel(left: vCut, top: panel.top, right: panel.right, bottom: hCut)
        let bl = Panel(left: panel.left, top: hCut, right: vCut, bottom: panel.bottom)
        let br = Panel(left: vCut, top: hCut, right: panel.right, bottom: panel.bottom)
        // Read each row in reading order, top row then bottom row.
        return rtl ? [tr, tl, br, bl] : [tl, tr, bl, br]
    }

    /// The original behavior for big, elongated, non-full-width panels: one cut → 2 pieces.
    private static func classicDivide(
        _ panel: Panel,
        _ bubbles: [Panel],
        _ pageAspect: Float,
        _ rtl: Bool,
        _ config: Config
    ) -> [Panel] {
        let inside = bubblesInside(panel, bubbles)
        if realAspect(panel, pageAspect) >= config.squareAspectHigh {
            return halveLeftRight(panel, inside, rtl, config) // wide → vertical cut
        }
        let cut = cutPosition(inside.map(\.top), inside.map(\.bottom), panel.top, panel.bottom, config)
        return [
            Panel(left: panel.left, top: panel.top, right: panel.right, bottom: cut),
            Panel(left: panel.left, top: cut, right: panel.right, bottom: panel.bottom),
        ] // tall → horizontal cut
    }

    private static func bubblesInside(_ panel: Panel, _ bubbles: [Panel]) -> [Panel] {
        bubbles.filter {
            $0.centerX >= panel.left && $0.centerX <= panel.right && $0.centerY >= panel.top && $0.centerY <= panel.bottom
        }
    }

    /// Picks the cut coordinate along an axis: the midpoint of the largest gap between consecutive
    /// bubble spans, clamped to the central band; falls back to the centre when there's no usable gap.
    private static func cutPosition(
        _ lowEdges: [Float],
        _ highEdges: [Float],
        _ start: Float,
        _ end: Float,
        _ config: Config
    ) -> Float {
        let center = (start + end) / 2
        let lo = start + (end - start) * config.cutCentralMin
        let hi = start + (end - start) * config.cutCentralMax

        if lowEdges.count >= 2 {
            let spans = zip(lowEdges, highEdges).sorted { $0.0 < $1.0 }
            var bestGap: Float = 0
            var bestMid = center
            var cursor = spans[0].1
            for k in 1..<spans.count {
                let (nextLow, nextHigh) = spans[k]
                let gap = nextLow - cursor
                if gap > bestGap {
                    bestGap = gap
                    bestMid = (cursor + nextLow) / 2
                }
                cursor = max(cursor, nextHigh)
            }
            if bestGap > 0 && bestMid >= lo && bestMid <= hi { return bestMid }
        }
        return min(max(center, lo), hi)
    }

    private static func isSmall(_ p: Panel, _ c: Config) -> Bool { p.area < c.smallAreaFraction }
    private static func isBig(_ p: Panel, _ c: Config) -> Bool { p.area > c.bigAreaFraction }
    private static func isFullWidth(_ p: Panel, _ c: Config, _ spread: Bool) -> Bool {
        p.width >= (spread ? c.spreadPageWidthFraction : c.fullWidthFraction)
    }
    private static func isSpread(_ pageAspect: Float, _ c: Config) -> Bool { pageAspect >= c.spreadAspectMin }
    private static func isCrossPage(_ p: Panel, _ c: Config) -> Bool { p.width >= c.crossPageWidthFraction }

    private static func realAspect(_ p: Panel, _ pageAspect: Float) -> Float {
        p.height <= 0 ? 1 : (p.width / p.height) * pageAspect
    }

    private static func isSquare(_ p: Panel, _ pageAspect: Float, _ c: Config) -> Bool {
        let a = realAspect(p, pageAspect)
        return a >= c.squareAspectLow && a <= c.squareAspectHigh
    }

    private static func adjacencyDir(_ a: Panel, _ b: Panel, _ c: Config) -> Dir {
        let vOverlap = overlap(a.top, a.bottom, b.top, b.bottom) / max(min(a.height, b.height), 1e-4)
        let hOverlap = overlap(a.left, a.right, b.left, b.right) / max(min(a.width, b.width), 1e-4)
        let hGap = max(max(a.left, b.left) - min(a.right, b.right), 0)
        let vGap = max(max(a.top, b.top) - min(a.bottom, b.bottom), 0)
        let sideBySide = vOverlap >= c.adjacencyOverlap && hGap <= c.adjacencyGap
        let stacked = hOverlap >= c.adjacencyOverlap && vGap <= c.adjacencyGap
        switch (sideBySide, stacked) {
        case (true, true): return hGap <= vGap ? .horizontal : .vertical
        case (true, false): return .horizontal
        case (false, true): return .vertical
        case (false, false): return .none
        }
    }

    private static func overlap(_ a0: Float, _ a1: Float, _ b0: Float, _ b1: Float) -> Float {
        max(min(a1, b1) - max(a0, b0), 0)
    }

    private static func union(_ a: Panel, _ b: Panel) -> Panel {
        Panel(left: min(a.left, b.left), top: min(a.top, b.top), right: max(a.right, b.right), bottom: max(a.bottom, b.bottom))
    }
}
