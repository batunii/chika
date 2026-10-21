/// Letterbox geometry for fitting a `pageW`×`pageH` image into a square `inputSize` model input,
/// preserving aspect with centered gray padding (YOLO's standard preprocessing). Platforms use this
/// to build the model input *and* to undo the transform when mapping detections back to the page,
/// so both steps stay consistent.
public struct Letterbox: Equatable, Sendable {
    public let scale: Float
    public let padX: Int
    public let padY: Int
    public let newW: Int
    public let newH: Int

    public static func fit(pageW: Int, pageH: Int, inputSize: Int) -> Letterbox {
        let scale = min(Float(inputSize) / Float(pageW), Float(inputSize) / Float(pageH))
        let newW = max(kotlinToInt(Float(pageW) * scale), 1)
        let newH = max(kotlinToInt(Float(pageH) * scale), 1)
        return Letterbox(scale: scale, padX: (inputSize - newW) / 2, padY: (inputSize - newH) / 2, newW: newW, newH: newH)
    }
}

/// Detected panels and speech bubbles in normalized page coordinates, plus the page pixel size.
public struct DetectResult: Equatable, Sendable {
    public let panels: [Panel]
    public let bubbles: [Panel]
    public let pageW: Int
    public let pageH: Int

    public init(panels: [Panel], bubbles: [Panel], pageW: Int, pageH: Int) {
        self.panels = panels
        self.bubbles = bubbles
        self.pageW = pageW
        self.pageH = pageH
    }
}

/// Decodes a YOLO panel/text detector's raw output tensor into `Panel`s in normalized page
/// coordinates. Platform-independent so Android (TFLite) and Apple (Core ML) produce identical
/// results from the same Manga109-trained model — only input building and inference differ per
/// platform. Class 0 = Panel, class 1 = Text/speech-balloon.
///
/// Handles the two common output layouts:
///  - end-to-end (NMS-free, e.g. YOLO26): `[1, numDet, 6]` rows of `[x1,y1,x2,y2,score,cls]`.
///  - raw: `[1, 4+nc, anchors]` or `[1, anchors, 4+nc]` of `[cx,cy,w,h,cls0,cls1]` → filter + NMS.
/// Coordinates may be normalized (≤1) or in input pixels; both are detected and handled.
public struct YoloPanelDecoder: Sendable {
    public static let panelClass = 0
    public static let textClass = 1

    // The single source of truth for decoder tuning: every platform detects with these exact values.
    public static let defaultInputSize = 640
    public static let defaultConfidence: Float = 0.25
    public static let defaultNmsIoU: Float = 0.45
    public static let defaultContainment: Float = 0.6
    public static let defaultMinAreaFraction: Float = 0.008

    public let inputSize: Int
    private let confidenceThreshold: Float
    private let nmsIoU: Float
    private let containmentThreshold: Float
    private let minAreaFraction: Float

    public init(
        inputSize: Int = YoloPanelDecoder.defaultInputSize,
        confidenceThreshold: Float = YoloPanelDecoder.defaultConfidence,
        nmsIoU: Float = YoloPanelDecoder.defaultNmsIoU,
        containmentThreshold: Float = YoloPanelDecoder.defaultContainment,
        minAreaFraction: Float = YoloPanelDecoder.defaultMinAreaFraction
    ) {
        self.inputSize = inputSize
        self.confidenceThreshold = confidenceThreshold
        self.nmsIoU = nmsIoU
        self.containmentThreshold = containmentThreshold
        self.minAreaFraction = minAreaFraction
    }

    /// `raw` is row-major in `shape` ([1, numDet, 6] or [1, attrs, anchors] / [1, anchors, attrs]).
    public func decode(raw: [Float], shape: [Int], letterbox lb: Letterbox, pageW: Int, pageH: Int) -> DetectResult {
        let empty = DetectResult(panels: [], bubbles: [], pageW: pageW, pageH: pageH)
        if shape.count != 3 { return empty }
        let d1 = shape[1]
        let d2 = shape[2]
        let transposed = d1 < d2 // [1, attrs, anchors]
        let attrs = transposed ? d1 : d2
        let preds = transposed ? d2 : d1
        func at(_ pred: Int, _ attr: Int) -> Float { transposed ? raw[attr * preds + pred] : raw[pred * attrs + attr] }

        if attrs < 6 { return empty }
        // A buffer shorter than its shape would trap here (Kotlin threw); treat it as no detections.
        if raw.count < attrs * preds { return empty }

        let endToEnd = preds <= 1000

        // Detect coordinate normalization by peeking at a few values.
        var maxCoord: Float = 0
        var sampled = 0
        var p = 0
        while p < preds && sampled < 64 {
            let a = at(p, 0), b = at(p, 1), c = at(p, 2), d = at(p, 3)
            // Kotlin's maxOf propagates NaN (so the row is skipped); Swift's max would drop it.
            let v = (a.isNaN || b.isNaN || c.isNaN || d.isNaN) ? Float.nan : max(a, b, c, d)
            if v.isFinite { maxCoord = max(maxCoord, v); sampled += 1 }
            p += 1
        }
        let coordScale: Float = maxCoord <= 1.5 ? Float(inputSize) : 1

        var panelBoxes: [[Float]] = [] // x1,y1,x2,y2,score (input-pixel space)
        var bubbleBoxes: [[Float]] = []

        for i in 0..<preds {
            let cls: Int
            let score: Float
            if endToEnd {
                score = at(i, 4)
                cls = kotlinToInt(at(i, 5))
            } else {
                let cls0 = at(i, 4), cls1 = at(i, 5)
                if cls0 >= cls1 { cls = Self.panelClass; score = cls0 } else { cls = Self.textClass; score = cls1 }
            }
            if score < confidenceThreshold || (cls != Self.panelClass && cls != Self.textClass) { continue }

            let a = at(i, 0) * coordScale
            let b = at(i, 1) * coordScale
            let c = at(i, 2) * coordScale
            let d = at(i, 3) * coordScale
            let x1: Float, y1: Float, x2: Float, y2: Float
            if endToEnd { x1 = a; y1 = b; x2 = c; y2 = d } // xyxy
            else { x1 = a - c / 2; y1 = b - d / 2; x2 = a + c / 2; y2 = b + d / 2 } // cxcywh
            let box = [x1, y1, x2, y2, score]
            if cls == Self.panelClass { panelBoxes.append(box) } else { bubbleBoxes.append(box) }
        }

        // Suppress overlapping/nested duplicates within each class.
        let panels = toPanels(suppress(panelBoxes), lb, pageW, pageH, minAreaFraction)
        let bubbles = toPanels(suppress(bubbleBoxes), lb, pageW, pageH, 0)
        return DetectResult(panels: panels, bubbles: bubbles, pageW: pageW, pageH: pageH)
    }

    /// Filters by min area, undoes the letterbox, and normalizes boxes to [0,1] page coordinates.
    private func toPanels(_ boxes: [[Float]], _ lb: Letterbox, _ pageW: Int, _ pageH: Int, _ minAreaFrac: Float) -> [Panel] {
        let minArea = minAreaFrac * Float(inputSize) * Float(inputSize)
        let padX = Float(lb.padX), padY = Float(lb.padY), w = Float(pageW), h = Float(pageH)
        return boxes.compactMap { box in
            let bw = max(box[2] - box[0], 0)
            let bh = max(box[3] - box[1], 0)
            if bw * bh < minArea { return nil }
            let l = min(max((box[0] - padX) / lb.scale / w, 0), 1)
            let t = min(max((box[1] - padY) / lb.scale / h, 0), 1)
            let r = min(max((box[2] - padX) / lb.scale / w, 0), 1)
            let bo = min(max((box[3] - padY) / lb.scale / h, 0), 1)
            return (r > l && bo > t) ? Panel(left: l, top: t, right: r, bottom: bo) : nil
        }
    }

    /// Greedy suppression by confidence: a box is dropped if it overlaps an already-kept box too
    /// much (IoU) or is largely contained within one. Removes duplicate detections and panels nested
    /// inside a larger panel.
    private func suppress(_ boxes: [[Float]]) -> [[Float]] {
        let sorted = boxes.sorted { $0[4] > $1[4] } // stable, like Kotlin's sortedByDescending
        var kept: [[Float]] = []
        for box in sorted {
            let redundant = kept.contains { iou($0, box) > nmsIoU || containedFraction(box, $0) > containmentThreshold }
            if redundant { continue }
            // A larger box can arrive after a smaller one it engulfs (the smaller scored higher), so
            // also evict any already-kept boxes now nested inside this one — we never keep a panel
            // inside another panel, whatever order they're processed in.
            kept.removeAll { containedFraction($0, box) > containmentThreshold }
            kept.append(box)
        }
        return kept
    }

    /// Fraction of `inner`'s area that lies inside `outer`.
    private func containedFraction(_ inner: [Float], _ outer: [Float]) -> Float {
        let ix = max(min(inner[2], outer[2]) - max(inner[0], outer[0]), 0)
        let iy = max(min(inner[3], outer[3]) - max(inner[1], outer[1]), 0)
        let inter = ix * iy
        let innerArea = (inner[2] - inner[0]) * (inner[3] - inner[1])
        return innerArea <= 0 ? 0 : inter / innerArea
    }

    private func iou(_ a: [Float], _ b: [Float]) -> Float {
        let ix = max(min(a[2], b[2]) - max(a[0], b[0]), 0)
        let iy = max(min(a[3], b[3]) - max(a[1], b[1]), 0)
        let inter = ix * iy
        let areaA = (a[2] - a[0]) * (a[3] - a[1])
        let areaB = (b[2] - b[0]) * (b[3] - b[1])
        let union = areaA + areaB - inter
        return union <= 0 ? 0 : inter / union
    }
}

/// Kotlin's `Float.toInt()`: truncates, NaN → 0, saturates to the Int32 range. Swift's `Int(_:)`
/// would trap on NaN/∞ from a bad model output or a zero-sized page instead.
private func kotlinToInt(_ v: Float) -> Int {
    if v.isNaN { return 0 }
    return Int(min(max(v, Float(Int32.min)), Float(Int32.max)))
}
