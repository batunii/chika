package com.napkin.comicreader.detection

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * Panel detector backed by the bundled Manga109-trained YOLO TFLite model
 * (`manga_panel_detector_int8.tflite`): class 0 = Panel, class 1 = Text. We keep only panels.
 *
 * The page is letterboxed into the model's 640×640 input; detections are decoded, filtered to
 * panels above [confidenceThreshold], de-duplicated with NMS, mapped back to page coordinates, and
 * returned in reading order. The interpreter isn't thread-safe, so [detect] is synchronized.
 *
 * YOLO TFLite exports vary in output layout, so [decode] handles the common shapes and the first
 * run logs the actual input/output tensor specs to make any remaining adjustment obvious.
 */
class MlPanelDetector private constructor(
    private val interpreter: Interpreter,
    private val confidenceThreshold: Float = 0.25f,
    private val nmsIoU: Float = 0.45f,
    private val containmentThreshold: Float = 0.6f,
    private val minAreaFraction: Float = 0.008f,
) : PanelSource {

    private val lock = Any()

    private val inputTensor = interpreter.getInputTensor(0)
    private val outputTensor = interpreter.getOutputTensor(0)
    private val inputSize = inputTensor.shape().let { if (it.size == 4) it[1] else 640 } // NHWC

    init {
        Log.i(
            TAG,
            "model loaded | input shape=${inputTensor.shape().toList()} type=${inputTensor.dataType()} " +
                "quant=${inputTensor.quantizationParams().scale}/${inputTensor.quantizationParams().zeroPoint} " +
                "| output shape=${outputTensor.shape().toList()} type=${outputTensor.dataType()} " +
                "quant=${outputTensor.quantizationParams().scale}/${outputTensor.quantizationParams().zeroPoint} " +
                "| outputs=${interpreter.outputTensorCount}",
        )
    }

    override fun detect(page: Bitmap, rightToLeft: Boolean): List<Panel> = synchronized(lock) {
        val panels = try {
            run(page)
        } catch (t: Throwable) {
            Log.e(TAG, "Inference failed; falling back to full page", t)
            emptyList()
        }
        if (panels.size < 2) listOf(Panel.FULL_PAGE) else PanelOrdering.order(panels, rightToLeft)
    }

    private fun run(page: Bitmap): List<Panel> {
        val bw = page.width
        val bh = page.height
        val scale = minOf(inputSize / bw.toFloat(), inputSize / bh.toFloat())
        val newW = (bw * scale).toInt().coerceAtLeast(1)
        val newH = (bh * scale).toInt().coerceAtLeast(1)
        val padX = (inputSize - newW) / 2
        val padY = (inputSize - newH) / 2

        val resized = Bitmap.createScaledBitmap(page, newW, newH, true)
        val input = buildInput(resized, newW, newH, padX, padY)
        if (resized != page) resized.recycle()

        val outBuf = ByteBuffer.allocateDirect(outputTensor.numBytes()).order(ByteOrder.nativeOrder())
        interpreter.run(input, outBuf)

        val raw = readFloats(outBuf, outputTensor)
        return decode(raw, outputTensor.shape(), scale, padX, padY, bw, bh)
    }

    /** Fills the model input buffer with the letterboxed RGB image (handles float or quantized). */
    private fun buildInput(resized: Bitmap, newW: Int, newH: Int, padX: Int, padY: Int): ByteBuffer {
        val float = inputTensor.dataType() == DataType.FLOAT32
        val bytesPer = if (float) 4 else 1
        val buf = ByteBuffer.allocateDirect(inputSize * inputSize * 3 * bytesPer)
            .order(ByteOrder.nativeOrder())

        val pixels = IntArray(newW * newH)
        resized.getPixels(pixels, 0, newW, 0, 0, newW, newH)
        val pad = 114 // YOLO letterbox gray

        for (y in 0 until inputSize) {
            val sy = y - padY
            for (x in 0 until inputSize) {
                val sx = x - padX
                var r = pad; var g = pad; var b = pad
                if (sx in 0 until newW && sy in 0 until newH) {
                    val px = pixels[sy * newW + sx]
                    r = (px shr 16) and 0xFF
                    g = (px shr 8) and 0xFF
                    b = px and 0xFF
                }
                if (float) {
                    buf.putFloat(r / 255f); buf.putFloat(g / 255f); buf.putFloat(b / 255f)
                } else {
                    buf.put(r.toByte()); buf.put(g.toByte()); buf.put(b.toByte())
                }
            }
        }
        buf.rewind()
        return buf
    }

    /** Reads the raw output buffer into floats, dequantizing if the model output is quantized. */
    private fun readFloats(buf: ByteBuffer, tensor: org.tensorflow.lite.Tensor): FloatArray {
        buf.rewind()
        val n = tensor.shape().fold(1) { a, b -> a * b }
        val out = FloatArray(n)
        when (tensor.dataType()) {
            DataType.FLOAT32 -> for (i in 0 until n) out[i] = buf.float
            DataType.UINT8 -> {
                val q = tensor.quantizationParams()
                for (i in 0 until n) out[i] = ((buf.get().toInt() and 0xFF) - q.zeroPoint) * q.scale
            }
            DataType.INT8 -> {
                val q = tensor.quantizationParams()
                for (i in 0 until n) out[i] = (buf.get().toInt() - q.zeroPoint) * q.scale
            }
            else -> for (i in 0 until n) out[i] = buf.float
        }
        return out
    }

    /**
     * Decodes YOLO output into panel boxes. Handles the two common layouts:
     *  - end-to-end (NMS-free): `[1, numDet, 6]` rows of `[x1,y1,x2,y2,score,cls]` (numDet small).
     *  - raw: `[1, 4+nc, anchors]` or `[1, anchors, 4+nc]` of `[cx,cy,w,h,cls0,cls1]` (anchors large)
     *    → confidence filter + NMS.
     * Coordinates may be normalized (≤1) or in input pixels; both are handled.
     */
    private fun decode(
        raw: FloatArray,
        shape: IntArray,
        scale: Float,
        padX: Int,
        padY: Int,
        bw: Int,
        bh: Int,
    ): List<Panel> {
        if (shape.size != 3) {
            Log.w(TAG, "Unexpected output rank ${shape.size}; shape=${shape.toList()}")
            return emptyList()
        }
        val d1 = shape[1]
        val d2 = shape[2]
        val transposed = d1 < d2          // [1, attrs, anchors]
        val attrs = if (transposed) d1 else d2
        val preds = if (transposed) d2 else d1
        fun at(pred: Int, attr: Int) = if (transposed) raw[attr * preds + pred] else raw[pred * attrs + attr]

        if (attrs < 6) {
            Log.w(TAG, "Unexpected attrs=$attrs (shape=${shape.toList()})")
            return emptyList()
        }

        val endToEnd = preds <= 1000
        val boxes = ArrayList<FloatArray>() // x1,y1,x2,y2,score (input-pixel space)

        // Detect coordinate normalization by peeking at a few values.
        var maxCoord = 0f
        var sampled = 0
        var p = 0
        while (p < preds && sampled < 64) {
            val v = maxOf(at(p, 0), at(p, 1), at(p, 2), at(p, 3))
            if (v.isFinite()) { maxCoord = maxOf(maxCoord, v); sampled++ }
            p++
        }
        val coordScale = if (maxCoord <= 1.5f) inputSize.toFloat() else 1f

        for (i in 0 until preds) {
            val score: Float
            val isPanel: Boolean
            if (endToEnd) {
                score = at(i, 4)
                isPanel = at(i, 5).toInt() == PANEL_CLASS
            } else {
                val cls0 = at(i, 4) // class 0 = Panel
                score = cls0
                isPanel = cls0 >= at(i, 5) // panel beats text
            }
            if (!isPanel || score < confidenceThreshold) continue

            val a = at(i, 0) * coordScale
            val b = at(i, 1) * coordScale
            val c = at(i, 2) * coordScale
            val d = at(i, 3) * coordScale
            val x1: Float; val y1: Float; val x2: Float; val y2: Float
            if (endToEnd) { x1 = a; y1 = b; x2 = c; y2 = d } // xyxy
            else { x1 = a - c / 2f; y1 = b - d / 2f; x2 = a + c / 2f; y2 = b + d / 2f } // cxcywh
            boxes.add(floatArrayOf(x1, y1, x2, y2, score))
        }

        // Always suppress overlapping/nested boxes — even the NMS-free model emits duplicates that
        // would otherwise make consecutive panels zoom into nearly the same region.
        val kept = suppress(boxes)
        val minArea = minAreaFraction * inputSize * inputSize

        val panels = kept.mapNotNull { box ->
            val w = (box[2] - box[0]).coerceAtLeast(0f)
            val h = (box[3] - box[1]).coerceAtLeast(0f)
            if (w * h < minArea) return@mapNotNull null
            // Undo letterbox → original pixels → normalized.
            val l = ((box[0] - padX) / scale / bw).coerceIn(0f, 1f)
            val t = ((box[1] - padY) / scale / bh).coerceIn(0f, 1f)
            val r = ((box[2] - padX) / scale / bw).coerceIn(0f, 1f)
            val bo = ((box[3] - padY) / scale / bh).coerceIn(0f, 1f)
            if (r > l && bo > t) Panel(l, t, r, bo) else null
        }

        Log.i(TAG, "ml decode: preds=$preds attrs=$attrs endToEnd=$endToEnd coordScale=$coordScale panels=${panels.size}")
        return panels
    }

    /**
     * Greedy suppression by confidence: a box is dropped if it overlaps an already-kept box too
     * much (IoU) or is largely contained within one. This removes duplicate detections and panels
     * nested inside a larger panel, which is what caused "zooms into the same region again".
     */
    private fun suppress(boxes: List<FloatArray>): List<FloatArray> {
        val sorted = boxes.sortedByDescending { it[4] }
        val kept = ArrayList<FloatArray>()
        for (box in sorted) {
            val redundant = kept.any { iou(it, box) > nmsIoU || containedFraction(box, it) > containmentThreshold }
            if (!redundant) kept.add(box)
        }
        return kept
    }

    /** Fraction of [inner]'s area that lies inside [outer]. */
    private fun containedFraction(inner: FloatArray, outer: FloatArray): Float {
        val ix = (minOf(inner[2], outer[2]) - maxOf(inner[0], outer[0])).coerceAtLeast(0f)
        val iy = (minOf(inner[3], outer[3]) - maxOf(inner[1], outer[1])).coerceAtLeast(0f)
        val inter = ix * iy
        val innerArea = (inner[2] - inner[0]) * (inner[3] - inner[1])
        return if (innerArea <= 0f) 0f else inter / innerArea
    }

    private fun iou(a: FloatArray, b: FloatArray): Float {
        val ix = (minOf(a[2], b[2]) - maxOf(a[0], b[0])).coerceAtLeast(0f)
        val iy = (minOf(a[3], b[3]) - maxOf(a[1], b[1])).coerceAtLeast(0f)
        val inter = ix * iy
        val areaA = (a[2] - a[0]) * (a[3] - a[1])
        val areaB = (b[2] - b[0]) * (b[3] - b[1])
        val union = areaA + areaB - inter
        return if (union <= 0f) 0f else inter / union
    }

    fun close() = runCatching { interpreter.close() }

    companion object {
        private const val TAG = "MlPanelDetector"
        private const val MODEL = "manga_panel_detector_int8.tflite"
        private const val PANEL_CLASS = 0

        /** Loads the bundled model; returns null (and logs) if it can't be loaded. */
        fun tryCreate(context: Context): MlPanelDetector? = try {
            val afd = context.assets.openFd(MODEL)
            val model = FileInputStream(afd.fileDescriptor).channel.use { ch ->
                ch.map(FileChannel.MapMode.READ_ONLY, afd.startOffset, afd.declaredLength)
            }
            afd.close()
            val options = Interpreter.Options().apply { numThreads = 4 }
            MlPanelDetector(Interpreter(model, options))
        } catch (t: Throwable) {
            Log.e(TAG, "Could not load TFLite model; ML detection disabled", t)
            null
        }
    }
}
