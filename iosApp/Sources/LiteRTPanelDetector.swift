import TensorFlowLite
import UIKit
import ChikaShared

/// On-device panel detector running the EXACT same TFLite model as the Android app
/// (`manga_panel_detector_int8.tflite`) via LiteRT/TensorFlow Lite, then the shared Kotlin decoder
/// + pipeline — so Android and iOS produce identical detections, ordering, and merge/divide
/// planning from the same weights. The model's I/O tensors are float32 ([1,640,640,3] in,
/// [1,300,6] out); int8 quantization is internal to the weights.
final class LiteRTPanelDetector {
    private let interpreter: Interpreter
    // The TFLite interpreter is not thread-safe; serialize inference (matching Android's lock) so
    // overlapping detections — e.g. while scrubbing pages — can't corrupt it and crash the app.
    private let lock = NSLock()
    // Built from the shared Kotlin defaults (the single source of truth Android also uses), so the
    // thresholds and input size can never drift between platforms. A loosened-gate diagnostic
    // (conf 0.08 / containment 0.9) recovered ZERO extra panels on dynamic manga layouts: this
    // end-to-end model emits high-confidence panels or nothing, so missed borderless panels are a
    // model-training limitation, not a threshold one. Improving them needs a retrained model.
    private let decoder = YoloPanelDecoder.companion.default()
    private var inputSize: Int { Int(decoder.inputSize) }

    /// nil if the bundled model is missing — callers fall back to whole-page reading.
    init?() {
        // QA hook: load an alternate bundled .tflite by name (for model A/B experiments).
        let modelName = ProcessInfo.processInfo.environment["CHIKA_DEBUG_MODEL"] ?? "manga_panel_detector_int8"
        guard let path = Bundle.main.path(forResource: modelName, ofType: "tflite") else {
            return nil
        }
        do {
            let interpreter = try Interpreter(modelPath: path)
            try interpreter.allocateTensors()
            self.interpreter = interpreter
        } catch {
            return nil
        }
    }

    func zoomRegions(for image: UIImage, rightToLeft: Bool) -> [Panel] {
        guard let cg = image.cgImage else { return [Panel.companion.FULL_PAGE] }
        let pageW = cg.width, pageH = cg.height
        let lb = Letterbox.companion.fit(pageW: Int32(pageW), pageH: Int32(pageH), inputSize: Int32(inputSize))
        guard let input = letterboxedFloatInput(cg, lb: lb) else { return [Panel.companion.FULL_PAGE] }

        lock.lock()
        defer { lock.unlock() }
        do {
            let inputData = input.withUnsafeBufferPointer { Data(buffer: $0) }
            try interpreter.copy(inputData, toInputAt: 0)
            try interpreter.invoke()
            let output = try interpreter.output(at: 0)

            let floats = output.data.toFloatArray()
            let shape = output.shape.dimensions
            let kRaw = KotlinFloatArray(size: Int32(floats.count))
            for (i, v) in floats.enumerated() { kRaw.set(index: Int32(i), value: v) }
            let kShape = KotlinIntArray(size: Int32(shape.count))
            for (i, d) in shape.enumerated() { kShape.set(index: Int32(i), value: Int32(d)) }

            let result = decoder.decode(raw: kRaw, shape: kShape, lb: lb, pageW: Int32(pageW), pageH: Int32(pageH))
            // EXACT Android parity: run the model's panels through the same shared pipeline
            // (PanelOrdering → PanelPlanner) and fall back to whole-page only when <2 regions remain —
            // identical to MlPanelDetector.detect on Android. Android applies NO GutterRefiner and NO
            // PanelReliability gate, so neither runs here.
            // QA hook: bypass the planner to see the model's RAW ordered detections (never set in prod).
            if ProcessInfo.processInfo.environment["CHIKA_DEBUG_RAW"] != nil {
                let ordered = PanelOrdering.shared.order(panels: result.panels, rightToLeft: rightToLeft)
                return ordered.count < 2 ? [Panel.companion.FULL_PAGE] : ordered
            }
            let planned = PanelPipeline.shared.zoomRegions(
                panels: result.panels, bubbles: result.bubbles,
                pageW: result.pageW, pageH: result.pageH, rightToLeft: rightToLeft
            )
            return planned.count < 2 ? [Panel.companion.FULL_PAGE] : planned
        } catch {
            return [Panel.companion.FULL_PAGE]
        }
    }

    /// Letterboxes the page into a 640×640×3 float buffer (NHWC, RGB, normalized 0–1, gray-114
    /// padding) — matching the Android preprocessing so both platforms feed the model identically.
    private func letterboxedFloatInput(_ cg: CGImage, lb: Letterbox) -> [Float]? {
        let size = inputSize
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue // bytes: R,G,B,A
            ) else { return false }
            // Bilinear (.medium) matches Android's Bitmap.createScaledBitmap(filter=true). Bicubic
            // (.high) perturbs pixels enough to flip borderline detections, breaking parity.
            ctx.interpolationQuality = .medium
            ctx.setFillColor(red: 114/255, green: 114/255, blue: 114/255, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            // NO flip: a raw CGBitmapContext already stores row 0 as the TOP scanline when a
            // CGImage is drawn upright in CG coordinates. (A translate/scale(1,-1) "flip" here fed
            // the model an upside-down page, so every detected box came back y-mirrored and the
            // reader framed the wrong panels — the "framing is off on device" bug.) CG's origin is
            // bottom-left, so the letterbox's TOP padding of padY maps to a draw rect at
            // y = size - padY - newH; the image's top scanline then lands at buffer row padY,
            // byte-identical to Android's placement even when the total padding is odd.
            ctx.draw(cg, in: CGRect(x: CGFloat(lb.padX),
                                    y: CGFloat(Int(size) - Int(lb.padY) - Int(lb.newH)),
                                    width: CGFloat(lb.newW), height: CGFloat(lb.newH)))
            return true
        }
        guard ok else { return nil }

        // Feed color RGB normalized 0–1, exactly matching Android's buildInput, so both platforms
        // hand the model identical pixels (input preprocessing is the only non-shared part of the
        // detection path, so it must match for detection parity).
        var floats = [Float](repeating: 0, count: size * size * 3)
        var di = 0
        var px = 0
        while px < rgba.count {
            floats[di] = Float(rgba[px]) / 255.0
            floats[di + 1] = Float(rgba[px + 1]) / 255.0
            floats[di + 2] = Float(rgba[px + 2]) / 255.0
            di += 3
            px += 4
        }
        return floats
    }
}

private extension Data {
    func toFloatArray() -> [Float] {
        let n = count / MemoryLayout<Float>.stride
        var out = [Float](repeating: 0, count: n)
        _ = out.withUnsafeMutableBytes { copyBytes(to: $0) }
        return out
    }
}
