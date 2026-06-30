package com.chakra.comicreader.detection

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
) : PanelSource {

    private val lock = Any()

    private val inputTensor = interpreter.getInputTensor(0)
    private val outputTensor = interpreter.getOutputTensor(0)
    private val inputSize = inputTensor.shape().let { if (it.size == 4) it[1] else 640 } // NHWC

    // YOLO output decoding (filter + NMS + letterbox-undo) is shared with iOS so both platforms
    // detect identically; only input building and inference are platform-specific here.
    private val decoder = YoloPanelDecoder(inputSize = inputSize)

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
        val result = try {
            run(page)
        } catch (t: Throwable) {
            Log.e(TAG, "Inference failed; falling back to full page", t)
            DetectResult(emptyList(), emptyList(), page.width, page.height)
        }
        // Single shared post-processing path (gap-fill → order → merge/divide), same as iOS.
        val planned = PanelPipeline.zoomRegions(
            result.panels, result.bubbles, result.pageW, result.pageH, rightToLeft,
        )
        Log.i(TAG, "panels=${result.panels.size} bubbles=${result.bubbles.size} planned=${planned.size}")
        if (planned.size < 2) listOf(Panel.FULL_PAGE) else planned
    }

    /** ML detections for one page, normalized to [0,1]; page dimensions are in pixels. */
    private fun run(page: Bitmap): DetectResult {
        val bw = page.width
        val bh = page.height
        val lb = Letterbox.fit(bw, bh, inputSize)

        val resized = Bitmap.createScaledBitmap(page, lb.newW, lb.newH, true)
        val input = buildInput(resized, lb.newW, lb.newH, lb.padX, lb.padY)
        if (resized != page) resized.recycle()

        val outBuf = ByteBuffer.allocateDirect(outputTensor.numBytes()).order(ByteOrder.nativeOrder())
        interpreter.run(input, outBuf)

        val raw = readFloats(outBuf, outputTensor)
        return decoder.decode(raw, outputTensor.shape(), lb, bw, bh)
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

    fun close() = runCatching { interpreter.close() }

    companion object {
        private const val TAG = "MlPanelDetector"
        private const val MODEL = "manga_panel_detector_int8.tflite"

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
