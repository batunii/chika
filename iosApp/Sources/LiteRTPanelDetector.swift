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
    private let inputSize = 640
    private let decoder = YoloPanelDecoder(
        inputSize: 640,
        confidenceThreshold: 0.25,
        nmsIoU: 0.45,
        containmentThreshold: 0.6,
        minAreaFraction: 0.008
    )

    /// nil if the bundled model is missing — callers fall back to whole-page reading.
    init?() {
        guard let path = Bundle.main.path(forResource: "manga_panel_detector_int8", ofType: "tflite") else {
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
            ctx.interpolationQuality = .high
            ctx.setFillColor(red: 114/255, green: 114/255, blue: 114/255, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            // Flip so row 0 of the buffer is the top of the page (upright, matching Android).
            ctx.translateBy(x: 0, y: CGFloat(size))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: CGFloat(lb.padX), y: CGFloat(lb.padY),
                                    width: CGFloat(lb.newW), height: CGFloat(lb.newH)))
            return true
        }
        guard ok else { return nil }

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
