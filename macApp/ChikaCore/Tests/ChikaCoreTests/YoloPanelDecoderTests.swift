import Testing
import ChikaCore

struct YoloPanelDecoderTests {
    let decoder = YoloPanelDecoder(inputSize: 640)

    /// Builds an end-to-end `[1, n, 6]` output (rows of x1,y1,x2,y2,score,cls) in pixel space.
    private func endToEnd(_ rows: [[Float]], capacity: Int = 300) -> ([Float], [Int]) {
        var raw = [Float](repeating: 0, count: capacity * 6)
        for (i, r) in rows.enumerated() { raw.replaceSubrange(i * 6 ..< i * 6 + 6, with: r) }
        return (raw, [1, capacity, 6])
    }

    private func decode(_ out: ([Float], [Int]), _ lb: Letterbox, _ w: Int = 640, _ h: Int = 640) -> DetectResult {
        decoder.decode(raw: out.0, shape: out.1, letterbox: lb, pageW: w, pageH: h)
    }

    @Test func decodesEndToEndBoxesIntoNormalizedPageCoords() throws {
        // Square page == square input, so no letterbox: pixel/640 maps straight to [0,1].
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        let result = decode(endToEnd([
            [64, 128, 320, 384, 0.9, 0], // panel
            [400, 100, 480, 200, 0.8, 1], // text/bubble
        ]), lb)

        #expect(result.panels.count == 1)
        #expect(result.bubbles.count == 1)
        let p = try #require(result.panels.first)
        near(0.1, p.left); near(0.2, p.top); near(0.5, p.right); near(0.6, p.bottom)
    }

    @Test func belowThresholdDetectionsAreDropped() {
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        let out = endToEnd([[64, 64, 320, 320, 0.10, 0]]) // < 0.25 default → dropped
        #expect(decode(out, lb).panels.isEmpty)
    }

    @Test func tinyPanelsAreFilteredByMinArea() {
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        // 10x10 px box → area 100 < minAreaFraction(0.008)*640*640 ≈ 3277.
        #expect(decode(endToEnd([[0, 0, 10, 10, 0.9, 0]]), lb).panels.isEmpty)
    }

    @Test func nestedDuplicatePanelsAreSuppressed() {
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        let out = endToEnd([
            [50, 50, 400, 400, 0.95, 0], // outer, higher score
            [60, 60, 390, 390, 0.90, 0], // mostly contained → dropped
        ])
        #expect(decode(out, lb).panels.count == 1)
    }

    @Test func largePanelEvictsHigherScoringNestedPanel() {
        // Page-57 case: a small panel scores higher than the huge panel that engulfs it. Suppression
        // must still drop the nested one (the larger box arrives second) — never keep panel-in-panel.
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        let out = endToEnd([
            [20, 8, 160, 150, 0.95, 0], // small, higher score, fully nested
            [0, 6, 640, 536, 0.90, 0],  // huge, lower score, engulfs the small one
        ])
        #expect(decode(out, lb).panels.count == 1)
    }

    @Test func partiallyOverlappingPanelsAreBothKept() {
        // A panel only ~⅓ inside a larger one (below the containment threshold) is a real neighbour
        // and must survive — guards the eviction above from being too aggressive.
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        let out = endToEnd([
            [0, 6, 640, 536, 0.90, 0],     // large upper region
            [309, 493, 566, 624, 0.85, 0], // ~33% inside it → kept
        ])
        #expect(decode(out, lb).panels.count == 2)
    }

    @Test func normalizedCoordsAreScaledToInput() throws {
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        // All coords ≤ 1 → decoder multiplies by inputSize.
        let panels = decode(endToEnd([[0.1, 0.2, 0.5, 0.6, 0.9, 0]]), lb).panels
        try #require(panels.count == 1)
        let p = panels[0]
        near(0.1, p.left); near(0.2, p.top); near(0.5, p.right); near(0.6, p.bottom)
    }

    @Test func letterboxIsUndoneForNonSquarePages() throws {
        // 1000x1500 page → scale 640/1500 ≈ 0.4267, newW ≈ 426, padX = (640-426)/2 = 107, padY = 0.
        let lb = Letterbox.fit(pageW: 1000, pageH: 1500, inputSize: 640)
        near(0.4267, lb.scale, 0.001)
        #expect(lb.padX == 107)
        #expect(lb.padY == 0)
        // A box spanning the full padded content width should map back to ~full page width.
        let out = endToEnd([[Float(lb.padX), 0, Float(lb.padX + lb.newW), 640, 0.9, 0]])
        let panels = decode(out, lb, 1000, 1500).panels
        try #require(panels.count == 1)
        near(0, panels[0].left); near(1, panels[0].right)
    }

    @Test func decodesRawTransposedLayoutWithCxcywh() throws {
        // Raw layout [1, 6, anchors] (transposed): attrs=6 rows, anchors columns; cxcywh + 2 classes.
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        let anchors = 8400
        var raw = [Float](repeating: 0, count: 6 * anchors)
        // Anchor 0: a panel centered at (192,256), size 256x256 → xyxy (64,128,320,384).
        func set(_ attr: Int, _ anchor: Int, _ v: Float) { raw[attr * anchors + anchor] = v }
        set(0, 0, 192); set(1, 0, 256); set(2, 0, 256); set(3, 0, 256)
        set(4, 0, 0.9); set(5, 0, 0.1) // cls0 (panel) wins
        let result = decoder.decode(raw: raw, shape: [1, 6, anchors], letterbox: lb, pageW: 640, pageH: 640)
        try #require(result.panels.count == 1)
        let p = result.panels[0]
        near(0.1, p.left); near(0.2, p.top); near(0.5, p.right); near(0.6, p.bottom)
    }

    @Test func malformedShapesReturnEmpty() {
        let lb = Letterbox.fit(pageW: 640, pageH: 640, inputSize: 640)
        let ten = [Float](repeating: 0, count: 10)
        #expect(decoder.decode(raw: ten, shape: [10], letterbox: lb, pageW: 640, pageH: 640).panels.isEmpty)
        #expect(decoder.decode(raw: ten, shape: [1, 5, 2], letterbox: lb, pageW: 640, pageH: 640).panels.isEmpty)
    }
}
