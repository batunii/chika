import CoreML
import CoreVideo
import UIKit
import ChikaShared

/// On-device panel detector for iOS. Runs the bundled Manga109-trained YOLO model (exported to
/// Core ML from the same weights as Android's TFLite model) and feeds the raw output through the
/// SHARED Kotlin decoder + pipeline, so iOS and Android produce identical panels, ordering, and
/// merge/divide planning. Class 0 = panel, class 1 = text/speech-balloon.
final class CoreMLPanelDetector {
    private let model: MLModel
    private let inputSize = 640
    private let decoder = YoloPanelDecoder(
        inputSize: 640,
        confidenceThreshold: 0.25,
        nmsIoU: 0.45,
        containmentThreshold: 0.6,
        minAreaFraction: 0.008
    )

    /// nil if the compiled model isn't in the bundle — callers fall back to whole-page reading.
    init?() {
        guard let url = Bundle.main.url(forResource: "MangaPanelDetector", withExtension: "mlmodelc") else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all // CPU + GPU + Neural Engine
        guard let model = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        self.model = model
    }

    /// Detects zoom regions in reading order. Returns [FULL_PAGE] when nothing usable is found, so
    /// the reader always has at least the whole page to show (matching the Android fallback).
    func zoomRegions(for image: UIImage, rightToLeft: Bool) -> [Panel] {
        guard let cg = image.cgImage else { return [Panel.companion.FULL_PAGE] }
        let pageW = cg.width
        let pageH = cg.height
        let lb = Letterbox.companion.fit(pageW: Int32(pageW), pageH: Int32(pageH), inputSize: Int32(inputSize))

        guard let pixelBuffer = letterboxedPixelBuffer(cg, lb: lb),
              let output = try? model.prediction(from: imageProvider(pixelBuffer)),
              let multiArray = firstMultiArray(output) else {
            return [Panel.companion.FULL_PAGE]
        }

        let (raw, shape) = floats(from: multiArray)
        let result = decoder.decode(
            raw: raw, shape: shape, lb: lb,
            pageW: Int32(pageW), pageH: Int32(pageH)
        )
        let planned = PanelPipeline.shared.zoomRegions(
            panels: result.panels, bubbles: result.bubbles,
            pageW: result.pageW, pageH: result.pageH, rightToLeft: rightToLeft
        )
        return planned.count < 2 ? [Panel.companion.FULL_PAGE] : planned
    }

    // MARK: - Core ML plumbing

    private func imageProvider(_ buffer: CVPixelBuffer) -> MLFeatureProvider {
        let name = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        return try! MLDictionaryFeatureProvider(
            dictionary: [name: MLFeatureValue(pixelBuffer: buffer)]
        )
    }

    private func firstMultiArray(_ provider: MLFeatureProvider) -> MLMultiArray? {
        for name in provider.featureNames {
            if let arr = provider.featureValue(for: name)?.multiArrayValue { return arr }
        }
        return nil
    }

    /// Flattens an MLMultiArray to a row-major [Float] plus its shape, matching what the shared
    /// Kotlin decoder expects (it handles both [1,n,6] and transposed layouts).
    private func floats(from arr: MLMultiArray) -> (KotlinFloatArray, KotlinIntArray) {
        let count = arr.count
        let kRaw = KotlinFloatArray(size: Int32(count))
        arr.dataPointer.withMemoryRebound(to: Float32.self, capacity: count) { ptr in
            for i in 0..<count { kRaw.set(index: Int32(i), value: ptr[i]) }
        }
        let kShape = KotlinIntArray(size: Int32(arr.shape.count))
        for (i, dim) in arr.shape.enumerated() { kShape.set(index: Int32(i), value: dim.int32Value) }
        return (kRaw, kShape)
    }

    /// Draws the page upright into a 640×640 BGRA buffer with centered gray (114) padding — YOLO's
    /// standard letterbox preprocessing, identical in geometry to the Android path.
    private func letterboxedPixelBuffer(_ cg: CGImage, lb: Letterbox) -> CVPixelBuffer? {
        let size = inputSize
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                  kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.setFillColor(red: 114/255, green: 114/255, blue: 114/255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // CGContext is bottom-left origin; flip so row 0 is the top of the page (model expects an
        // upright image). The letterbox rect uses padY from the top, so y is measured from the top.
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)
        let rect = CGRect(x: CGFloat(lb.padX), y: CGFloat(lb.padY),
                          width: CGFloat(lb.newW), height: CGFloat(lb.newH))
        ctx.draw(cg, in: rect)
        return buffer
    }
}
