import Testing
import ChikaCore

struct PanelPlannerTests {
    let pageW = 1000
    let pageH = 1500

    private func plan(_ panels: [Panel], bubbles: [Panel] = [], rightToLeft: Bool = false) -> [Panel] {
        PanelPlanner.plan(ordered: panels, bubbles: bubbles, pageW: pageW, pageH: pageH, rightToLeft: rightToLeft)
    }

    private func plan(_ panels: [Panel], _ w: Int, _ h: Int, _ rtl: Bool) -> [Panel] {
        PanelPlanner.plan(ordered: panels, bubbles: [], pageW: w, pageH: h, rightToLeft: rtl)
    }

    @Test func emptyInputPassesThrough() {
        #expect(plan([]) == [])
    }

    @Test func normalPanelsAreLeftAsIs() {
        // Area ~0.2 each: neither small (<0.10) nor big (>0.35).
        let a = Panel(0.0, 0.0, 0.5, 0.4)
        let b = Panel(0.5, 0.0, 1.0, 0.4)
        #expect(plan([a, b]) == [a, b])
    }

    @Test func adjacentSmallPanelsMergeIntoOneRegion() {
        // Three tiny side-by-side panels in one strip (area 0.03 each, gaps < 0.05).
        let p1 = Panel(0.00, 0.0, 0.15, 0.2)
        let p2 = Panel(0.17, 0.0, 0.32, 0.2)
        let p3 = Panel(0.34, 0.0, 0.49, 0.2)
        #expect(plan([p1, p2, p3]) == [Panel(0.00, 0.0, 0.49, 0.2)])
    }

    @Test func mergeStopsAtMaxMergeCount() throws {
        // Four tiny adjacent panels; default cap is 3, so the run chunks 3 + 1.
        let panels = (0..<4).map { i in Panel(Float(i) * 0.12, 0.0, Float(i) * 0.12 + 0.10, 0.2) }
        let result = plan(panels)
        try #require(result.count == 2)
        #expect(panels[0].left == result[0].left)
        #expect(panels[2].right == result[0].right)
        #expect(panels[3] == result[1])
    }

    @Test func distantSmallPanelsDoNotMerge() {
        let p1 = Panel(0.0, 0.0, 0.15, 0.2)
        let p2 = Panel(0.5, 0.0, 0.65, 0.2) // gap 0.35 >> adjacencyGap
        #expect(plan([p1, p2]) == [p1, p2])
    }

    @Test func bigWidePanelIsDividedWithVerticalCut() throws {
        // Area 0.5, pixel aspect (0.9/0.55)*(1000/1500) ≈ 1.09... make it clearly wide:
        // width 0.95, height 0.4 → area 0.38 > 0.35; aspect (0.95/0.4)*(2/3) ≈ 1.58 > 1.25.
        let wide = Panel(0.0, 0.0, 0.95, 0.4)
        let result = plan([wide])
        try #require(result.count == 2)
        let first = result[0], second = result[1]
        #expect(wide.left == first.left)
        #expect(wide.right == second.right)
        #expect(first.right == second.left) // pieces share the cut
        #expect(wide.top == first.top)
        #expect(wide.bottom == first.bottom)
    }

    @Test func rightToLeftDivisionEmitsRightPieceFirst() throws {
        let wide = Panel(0.0, 0.0, 0.95, 0.4)
        let result = plan([wide], rightToLeft: true)
        try #require(result.count == 2)
        #expect(result[0].left > result[1].left)
    }

    @Test func bigSquarePanelIsTreatedAsSplashAndKept() {
        // Pixel aspect (0.75/0.5)*(1000/1500) = 1.0 → square; area 0.375 > 0.35 but never divided.
        let splash = Panel(0.1, 0.2, 0.85, 0.7)
        #expect(plan([splash]) == [splash])
    }

    @Test func cutAvoidsBubblesByFallingInLargestGap() throws {
        let wide = Panel(0.0, 0.0, 0.95, 0.4)
        // Two bubble groups: one on the far left, one on the far right; gap centre ≈ 0.475.
        let bubbles = [
            Panel(0.05, 0.1, 0.30, 0.3),
            Panel(0.65, 0.1, 0.90, 0.3),
        ]
        let result = plan([wide], bubbles: bubbles)
        try #require(result.count == 2)
        let cut = result[0].right
        near(0.475, cut, 0.01)
        // The cut must not slice through either bubble.
        for bubble in bubbles {
            #expect(cut <= bubble.left || cut >= bubble.right, "cut \(cut) slices bubble \(bubble)")
        }
    }

    @Test func fullWidthBroadPanelSplitsIntoFour() throws {
        // Full width (0.96) AND broad/tall (0.75) → 2×2 grid, read TL, TR, BL, BR.
        let p = Panel(0.0, 0.10, 0.96, 0.85)
        let r = plan([p])
        try #require(r.count == 4)
        // corners
        #expect(p.left == r[0].left); #expect(p.top == r[0].top)        // TL
        #expect(p.right == r[1].right); #expect(p.top == r[1].top)      // TR
        #expect(p.left == r[2].left); #expect(p.bottom == r[2].bottom)  // BL
        #expect(p.right == r[3].right); #expect(p.bottom == r[3].bottom) // BR
        // shared cuts
        #expect(r[0].right == r[1].left)  // vertical cut
        #expect(r[0].bottom == r[2].top)  // horizontal cut
        #expect(r[1].bottom == r[3].top)
    }

    @Test func fullWidthShortPanelStillSplitsIntoTwo() throws {
        // Full width (0.95) but short (0.30, not broad) → 2 side-by-side.
        let p = Panel(0.0, 0.0, 0.95, 0.30)
        let r = plan([p])
        try #require(r.count == 2)
        #expect(r[0].right == r[1].left)
    }

    @Test func doublePageBroadPanelReadsRowMajorAcrossBothPages() throws {
        // Landscape spread (aspect ≈1.47), a panel spanning both pages, broad → 4 cols × 2 rows = 8,
        // read as ONE image: the whole top row (across both pages) before the bottom row.
        let spread = Panel(0.0, 0.10, 1.0, 0.85)
        let r = plan([spread], 2200, 1500, false)
        try #require(r.count == 8)
        let mid: Float = (0.10 + 0.85) / 2
        #expect(r.prefix(4).allSatisfy { $0.bottom <= mid + 1e-3 }, "first 4 = top row (across both pages)")
        #expect(r.dropFirst(4).allSatisfy { $0.top >= mid - 1e-3 }, "last 4 = bottom row")
        // The top row crosses the seam left→right (a left-page piece, then a right-page piece).
        #expect(r[0].left < r[1].left && r[1].left < r[2].left && r[2].left < r[3].left)
        #expect(r[0].right <= 0.5 + 1e-3 && r[3].left >= 0.5 - 1e-3, "row spans both pages")
    }

    @Test func doublePageShortPanelSplitsIntoFourAcross() throws {
        // Short cross-page panel → a single row of 4 across the full width, left→right.
        let spread = Panel(0.0, 0.30, 1.0, 0.60)
        let r = plan([spread], 2200, 1500, false)
        try #require(r.count == 4)
        #expect(r[0].left < r[1].left && r[1].left < r[2].left && r[2].left < r[3].left, "left→right")
    }

    @Test func doublePageRightToLeftReadsRightmostFirst() throws {
        let spread = Panel(0.0, 0.30, 1.0, 0.60)
        let r = plan([spread], 2200, 1500, true)
        try #require(r.count == 4)
        #expect(r[0].left > r[1].left && r[1].left > r[2].left, "right→left across the spread")
        #expect(r[0].right >= 1.0 - 1e-3, "starts at the far right")
    }

    @Test func spreadPerPagePanelsAreEachBrokenUp() {
        // Spread (aspect ≈1.47) with one big panel per page. Neither spans both pages, but each fills
        // its own page → each split into 4 → 8 total.
        let leftPage = Panel(0.02, 0.10, 0.48, 0.90)
        let rightPage = Panel(0.52, 0.10, 0.98, 0.90)
        #expect(plan([leftPage, rightPage], 2200, 1500, false).count == 8)
    }

    @Test func modestlyWideSpreadIsStillTreatedAsSpread() throws {
        // Two portrait pages side by side give aspect ≈1.3 (below the old 1.4 cutoff) → still a spread:
        // 4 cols × 2 rows = 8, read row-major (top row across both pages first).
        let spread = Panel(0.0, 0.0, 1.0, 1.0)
        let r = plan([spread], 3974, 3056, false)
        try #require(r.count == 8)
        #expect(r.prefix(4).allSatisfy { $0.bottom <= 0.5 + 1e-3 }, "top row first")
        #expect(r.dropFirst(4).allSatisfy { $0.top >= 0.5 - 1e-3 }, "bottom row second")
    }

    @Test func perPageWidthRuleAppliesOnlyToSpreads() {
        // A half-page-wide, short panel: on a portrait page it's neither full-width nor big → kept
        // whole; on a landscape spread it fills one page → split into 2.
        let p = Panel(0.04, 0.35, 0.50, 0.65) // width 0.46, height 0.30
        #expect(plan([p], 1000, 1500, false).count == 1) // portrait
        #expect(plan([p], 2200, 1500, false).count == 2) // spread
    }
}
