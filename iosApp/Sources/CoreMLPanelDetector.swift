import CoreML
import CoreVideo
import UIKit
import ChikaShared

/// On-device panel detector running the same YOLO26n weights as the Android app via Core ML (so it
/// also runs under Mac Catalyst, which TensorFlow Lite doesn't ship for), then the shared Kotlin
/// decoder + pipeline — so Android and Apple share detections decoding, ordering, and merge/divide
/// planning. `MangaPanelDetector.mlpackage` is exported from the upstream FP32 weights by
/// training/scripts/export_coreml.py: a 640×640 RGB image in (Core ML scales it to 0–1), [1,300,6]
/// out. Android's .tflite is the int8-quantized export of the same weights, so the two agree except
/// where quantization nudges a borderline score across the confidence threshold.
final class CoreMLPanelDetector {
    private let model: MLModel
    // Serialize inference (matching Android's lock) so overlapping detections — e.g. while
    // scrubbing pages — each get the model to themselves.
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
        // QA hook: load an alternate bundled model by name (for model A/B experiments).
        let modelName = ChikaDebug.env("CHIKA_DEBUG_MODEL") ?? "MangaPanelDetector"
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else {
            return nil
        }
        self.model = model
    }

    func zoomRegions(for image: UIImage, rightToLeft: Bool) -> [Panel] {
        guard let cg = image.cgImage else { return [Panel.companion.FULL_PAGE] }
        let pageW = cg.width, pageH = cg.height
        let lb = Letterbox.companion.fit(pageW: Int32(pageW), pageH: Int32(pageH), inputSize: Int32(inputSize))
        guard let input = letterboxedPixelBuffer(cg, lb: lb) else { return [Panel.companion.FULL_PAGE] }

        lock.lock()
        defer { lock.unlock() }
        do {
            let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
            guard let output = try model.prediction(from: features).featureValue(for: "output")?.multiArrayValue else {
                return [Panel.companion.FULL_PAGE]
            }

            // MLShapedArray copies out in row-major order regardless of the output's memory strides.
            let floats = MLShapedArray<Float>(output).scalars
            let shape = output.shape.map { $0.intValue }
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
            if ChikaDebug.env("CHIKA_DEBUG_RAW") != nil {
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

    /// Letterboxes the page into a 640×640 BGRA pixel buffer with gray-114 padding — matching the
    /// Android preprocessing so both platforms feed the model the same pixels.
    private func letterboxedPixelBuffer(_ cg: CGImage, lb: Letterbox) -> CVPixelBuffer? {
        let size = inputSize
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            // Little-endian premultiplied-first = bytes B,G,R,A — the layout of 32BGRA. The page is
            // drawn over an opaque fill, so premultiplication never changes a pixel.
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
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
        return buffer
    }
}
