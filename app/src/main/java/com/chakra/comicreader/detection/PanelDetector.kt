package com.chakra.comicreader.detection

import android.graphics.Bitmap
import android.util.Log
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.Mat
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc

/**
 * Detects comic panels by **accumulating evidence for each candidate box and scoring its
 * probability** — no ML. This is robust to the things that break single-contour detection: a speech
 * bubble interrupting a border, a broken/open border, or content touching the border. A box can be
 * confirmed by its corners plus partial edges even when one edge is occluded.
 *
 * Pipeline:
 *  1. **Preprocess** — downscale, grayscale; detect light/dark polarity so it works on both
 *     white-gutter and dark-background comics; threshold so borders/ink are foreground.
 *  2. **Evidence maps** — extract long horizontal/vertical line segments (panel borders; gaps from
 *     bubbles are bridged), and keep an ink map for gutters/content. Build integral images for O(1)
 *     region queries.
 *  3. **Candidate lines** — the rows/columns that carry a border line or a blank gutter become the
 *     grid of candidate box edges (intersections = corners/vertices).
 *  4. **Hypothesize & score** — every rectangle spanned by a pair of horizontal and a pair of
 *     vertical candidate lines is scored: `P = wEdge·edgeSupport + wCorner·cornerSupport +
 *     wContent·contentPlausibility`, where each edge is "supported" by a border line, an outside
 *     gutter, or the page boundary. Corner support (line junctions) is what rescues bubble-broken
 *     edges.
 *  5. **Select** — greedily keep the highest-probability, non-overlapping boxes above a threshold.
 *     Below threshold the page falls back to a single full-page view (conservative by design).
 */
class PanelDetector(
    private val config: Config = Config(),
) : PanelSource {
    data class Config(
        val workingMaxDimension: Int = 1400,
        /** Min straight-line length to count as a border, as a fraction of the page dimension. */
        val lineKernelFraction: Float = 0.12f,
        /** Bridge gaps in a border line (e.g. where a bubble crosses it), fraction of dimension. */
        val lineBridgeFraction: Float = 0.05f,
        /** Tolerance band when matching a hypothesized edge to a real line, fraction of long edge. */
        val lineToleranceFraction: Float = 0.004f,
        /** A row/col is a "line" if at least this fraction of it is covered by border ink. */
        val lineCoverageMin: Float = 0.10f,
        /** A row/col is "blank" if at most this fraction of it is ink. */
        val blankFraction: Float = 0.012f,
        /** Minimum blank-gutter thickness, fraction of long edge. */
        val minGutterFraction: Float = 0.006f,
        /** Thickness of the just-outside band used to check for a gutter, fraction of long edge. */
        val gutterBandFraction: Float = 0.012f,
        /** Window around a corner used to look for a line junction, fraction of long edge. */
        val cornerWindowFraction: Float = 0.02f,
        /** Candidate lines closer than this (fraction of long edge) are merged. */
        val lineClusterFraction: Float = 0.012f,
        /** Cap on candidate lines per axis (bounds the number of hypotheses). */
        val maxLinesPerAxis: Int = 12,
        val minAreaFraction: Float = 0.02f,
        val maxAreaFraction: Float = 0.98f,
        val minEdgeFraction: Float = 0.07f,
        // Probability weights (sum to 1) and acceptance threshold.
        val wEdge: Float = 0.45f,
        val wCorner: Float = 0.30f,
        val wContent: Float = 0.25f,
        /** Minimum P(box) to zoom into a box; higher = more conservative (prefer full-page). */
        val zoomThreshold: Float = 0.45f,
        val contentMin: Float = 0.02f,
        val contentMax: Float = 0.9f,
        /** Two accepted boxes may not overlap by more than this IoU. */
        val selectMaxIoU: Float = 0.15f,
    )

    private data class Scored(val l: Int, val t: Int, val r: Int, val b: Int, val p: Float) {
        val area: Long get() = (r - l).toLong() * (b - t).toLong()
    }

    override fun detect(page: Bitmap, rightToLeft: Boolean): List<Panel> {
        val boxes = try {
            runDetection(page)
        } catch (t: Throwable) {
            Log.e(TAG, "Panel detection failed; falling back to full page", t)
            emptyList()
        }
        if (boxes.size < 2) return listOf(Panel.FULL_PAGE)
        return PanelOrdering.order(boxes, rightToLeft)
    }

    private fun runDetection(page: Bitmap): List<Panel> {
        val src = Mat()
        Utils.bitmapToMat(page, src)

        val longEdge0 = maxOf(src.width(), src.height())
        val scale = if (longEdge0 > config.workingMaxDimension)
            config.workingMaxDimension.toDouble() / longEdge0 else 1.0
        val work = Mat()
        if (scale < 1.0) Imgproc.resize(src, work, Size(), scale, scale, Imgproc.INTER_AREA)
        else src.copyTo(work)
        src.release()

        val gray = Mat()
        Imgproc.cvtColor(work, gray, Imgproc.COLOR_RGBA2GRAY)
        work.release()
        Imgproc.GaussianBlur(gray, gray, Size(3.0, 3.0), 0.0)

        val w = gray.width()
        val h = gray.height()
        val edge = maxOf(w, h)

        // Polarity: dark ink on light paper (normal) vs light ink on dark paper.
        val meanGray = Core.mean(gray).`val`[0]
        val flag = if (meanGray >= 110.0) Imgproc.THRESH_BINARY_INV else Imgproc.THRESH_BINARY
        val ink = Mat()
        Imgproc.threshold(gray, ink, 0.0, 255.0, flag or Imgproc.THRESH_OTSU)
        gray.release()

        // --- Evidence: long horizontal & vertical line segments (panel borders) ---
        val lh = maxOf(8, (config.lineKernelFraction * w).toInt())
        val lv = maxOf(8, (config.lineKernelFraction * h).toInt())
        val bridgeH = maxOf(2, (config.lineBridgeFraction * w).toInt())
        val bridgeV = maxOf(2, (config.lineBridgeFraction * h).toInt())
        val tol = maxOf(2, (config.lineToleranceFraction * edge).toInt())

        val hLines = extractLines(ink, lh, 1, bridgeH, 1)
        val vLines = extractLines(ink, 1, lv, 1, bridgeV)

        // Dilate lines across the tolerance band so a single-row/col query gives true coverage.
        val hDil = dilate(hLines, 1, 2 * tol + 1)
        val vDil = dilate(vLines, 2 * tol + 1, 1)

        // Integral images.
        val inkInt = Integral(toBytes(ink), w, h)
        val hInt = Integral(toBytes(hDil), w, h)
        val vInt = Integral(toBytes(vDil), w, h)

        // Row/column projections (undilated) to locate candidate line/gutter positions.
        val hLineRows = rowProjection(toBytes(hLines), w, h)
        val vLineCols = colProjection(toBytes(vLines), w, h)
        val inkRows = rowProjection(toBytes(ink), w, h)
        val inkCols = colProjection(toBytes(ink), w, h)

        ink.release(); hLines.release(); vLines.release(); hDil.release(); vDil.release()

        val ys = candidateLines(hLineRows, inkRows, w, h, edge)
        val xs = candidateLines(vLineCols, inkCols, h, w, edge)

        val evaluator = Evaluator(inkInt, hInt, vInt, w, h, edge, config)
        val pageArea = (w.toLong() * h.toLong()).coerceAtLeast(1L)
        val minArea = config.minAreaFraction * pageArea
        val maxArea = config.maxAreaFraction * pageArea
        val minW = config.minEdgeFraction * w
        val minH = config.minEdgeFraction * h

        val hypotheses = ArrayList<Scored>()
        for (yi in ys.indices) for (yj in yi + 1 until ys.size) {
            val top = ys[yi]; val bottom = ys[yj]
            if (bottom - top < minH) continue
            for (xi in xs.indices) for (xj in xi + 1 until xs.size) {
                val left = xs[xi]; val right = xs[xj]
                if (right - left < minW) continue
                val area = (right - left).toLong() * (bottom - top).toLong()
                if (area < minArea || area > maxArea) continue
                val p = evaluator.score(left, top, right, bottom)
                hypotheses.add(Scored(left, top, right, bottom, p))
            }
        }

        val chosen = select(hypotheses)
        val topP = hypotheses.sortedByDescending { it.p }.take(6)
            .joinToString(prefix = "[", postfix = "]") { String.format("%.2f", it.p) }
        Log.i(
            TAG,
            "lines x=${xs.size} y=${ys.size} | hypotheses=${hypotheses.size} topP=$topP " +
                "| threshold=${config.zoomThreshold} chosen=${chosen.size}",
        )

        return chosen.map {
            Panel(it.l / w.toFloat(), it.t / h.toFloat(), it.r / w.toFloat(), it.b / h.toFloat())
        }
    }

    /** Greedy: keep highest-probability boxes that don't substantially overlap an accepted one. */
    private fun select(hypotheses: List<Scored>): List<Scored> {
        val chosen = ArrayList<Scored>()
        for (c in hypotheses.filter { it.p >= config.zoomThreshold }.sortedByDescending { it.p }) {
            val conflict = chosen.any { iou(it, c) >= config.selectMaxIoU || containment(it, c) >= 0.6f }
            if (!conflict) chosen.add(c)
        }
        return chosen
    }

    private fun extractLines(ink: Mat, kw: Int, kh: Int, bridgeW: Int, bridgeH: Int): Mat {
        val out = Mat()
        val openK = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(kw.toDouble(), kh.toDouble()))
        Imgproc.morphologyEx(ink, out, Imgproc.MORPH_OPEN, openK)
        val bridgeK = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(bridgeW.toDouble(), bridgeH.toDouble()))
        Imgproc.morphologyEx(out, out, Imgproc.MORPH_CLOSE, bridgeK)
        return out
    }

    private fun dilate(src: Mat, kw: Int, kh: Int): Mat {
        val out = Mat()
        val k = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(kw.toDouble(), kh.toDouble()))
        Imgproc.dilate(src, out, k)
        return out
    }

    private fun toBytes(mask: Mat): ByteArray {
        val bytes = ByteArray(mask.width() * mask.height())
        mask.get(0, 0, bytes)
        return bytes
    }

    private fun rowProjection(mask: ByteArray, w: Int, h: Int): IntArray {
        val proj = IntArray(h)
        for (y in 0 until h) {
            var c = 0
            val base = y * w
            for (x in 0 until w) if (mask[base + x].toInt() != 0) c++
            proj[y] = c
        }
        return proj
    }

    private fun colProjection(mask: ByteArray, w: Int, h: Int): IntArray {
        val proj = IntArray(w)
        for (y in 0 until h) {
            val base = y * w
            for (x in 0 until w) if (mask[base + x].toInt() != 0) proj[x]++
        }
        return proj
    }

    /**
     * Candidate edge positions along one axis: positions of border lines (projection peaks) and of
     * blank gutters, plus the two page edges; clustered and capped.
     *
     * @param lineProj per-index border-line pixel count, length = [axisLen]
     * @param inkProj per-index ink pixel count, length = [axisLen]
     * @param crossLen length of the perpendicular axis (used to normalize coverage)
     */
    private fun candidateLines(
        lineProj: IntArray,
        inkProj: IntArray,
        crossLen: Int,
        axisLen: Int,
        edge: Int,
    ): IntArray {
        val positions = sortedSetOf(0, axisLen)
        val lineMin = (config.lineCoverageMin * crossLen).toInt()
        val blankMax = (config.blankFraction * crossLen).toInt()
        val minGutter = maxOf(3, (config.minGutterFraction * edge).toInt())

        // Border-line centers: maximal runs above the coverage floor → take the run centre.
        var i = 0
        while (i < axisLen) {
            if (lineProj[i] >= lineMin) {
                val start = i
                while (i < axisLen && lineProj[i] >= lineMin) i++
                positions.add((start + i) / 2)
            } else i++
        }
        // Gutter centers: maximal blank runs thick enough → centre.
        i = 0
        while (i < axisLen) {
            if (inkProj[i] <= blankMax) {
                val start = i
                while (i < axisLen && inkProj[i] <= blankMax) i++
                if (i - start >= minGutter) positions.add((start + i) / 2)
            } else i++
        }

        return clusterAndCap(positions.toIntArray(), (config.lineClusterFraction * edge).toInt())
    }

    private fun clusterAndCap(sorted: IntArray, clusterDist: Int): IntArray {
        if (sorted.isEmpty()) return sorted
        val merged = ArrayList<Int>()
        var groupStart = sorted[0]
        var prev = sorted[0]
        for (k in 1 until sorted.size) {
            val v = sorted[k]
            if (v - prev <= clusterDist) {
                prev = v
            } else {
                merged.add((groupStart + prev) / 2)
                groupStart = v
                prev = v
            }
        }
        merged.add((groupStart + prev) / 2)

        if (merged.size <= config.maxLinesPerAxis) return merged.toIntArray()
        // Too many: keep endpoints and an evenly-spaced subset.
        val result = sortedSetOf(merged.first(), merged.last())
        val step = (merged.size - 1).toFloat() / (config.maxLinesPerAxis - 1)
        var idx = 0f
        while (idx < merged.size) {
            result.add(merged[idx.toInt().coerceIn(0, merged.size - 1)])
            idx += step
        }
        return result.toIntArray()
    }

    private fun iou(a: Scored, b: Scored): Float {
        val ix = (minOf(a.r, b.r) - maxOf(a.l, b.l)).coerceAtLeast(0)
        val iy = (minOf(a.b, b.b) - maxOf(a.t, b.t)).coerceAtLeast(0)
        val inter = ix.toLong() * iy.toLong()
        val union = a.area + b.area - inter
        return if (union <= 0) 0f else inter.toFloat() / union
    }

    private fun containment(a: Scored, b: Scored): Float {
        val ix = (minOf(a.r, b.r) - maxOf(a.l, b.l)).coerceAtLeast(0)
        val iy = (minOf(a.b, b.b) - maxOf(a.t, b.t)).coerceAtLeast(0)
        val inter = ix.toLong() * iy.toLong()
        val smaller = minOf(a.area, b.area).coerceAtLeast(1)
        return inter.toFloat() / smaller
    }

    /** Summed-area table of a 0/255 mask (counts set pixels); size (w+1)*(h+1). */
    private class Integral(mask: ByteArray, val w: Int, val h: Int) {
        private val stride = w + 1
        private val data = IntArray(stride * (h + 1))

        init {
            for (y in 0 until h) {
                var rowSum = 0
                val maskRow = y * w
                val cur = (y + 1) * stride
                val prev = y * stride
                for (x in 0 until w) {
                    if (mask[maskRow + x].toInt() != 0) rowSum++
                    data[cur + x + 1] = data[prev + x + 1] + rowSum
                }
            }
        }

        fun sum(x0: Int, y0: Int, x1: Int, y1: Int): Int {
            val ax = x0.coerceIn(0, w); val ay = y0.coerceIn(0, h)
            val bx = x1.coerceIn(0, w); val by = y1.coerceIn(0, h)
            if (bx <= ax || by <= ay) return 0
            return data[by * stride + bx] - data[ay * stride + bx] -
                data[by * stride + ax] + data[ay * stride + ax]
        }
    }

    /** Computes P(box) from edge support, corner support, and content plausibility. */
    private class Evaluator(
        private val inkInt: Integral,
        private val hInt: Integral,
        private val vInt: Integral,
        private val w: Int,
        private val h: Int,
        edge: Int,
        private val cfg: Config,
    ) {
        private val gutterBand = maxOf(2, (cfg.gutterBandFraction * edge).toInt())
        private val cornerWin = maxOf(3, (cfg.cornerWindowFraction * edge).toInt())

        fun score(l: Int, t: Int, r: Int, b: Int): Float {
            val sTop = edgeSupport(border = hCov(l, r, t), gutter = gutterTop(l, r, t), page = t <= 0)
            val sBot = edgeSupport(border = hCov(l, r, b), gutter = gutterBottom(l, r, b), page = b >= h)
            val sLeft = edgeSupport(border = vCov(t, b, l), gutter = gutterLeft(t, b, l), page = l <= 0)
            val sRight = edgeSupport(border = vCov(t, b, r), gutter = gutterRight(t, b, r), page = r >= w)
            val edgeSupport = (sTop + sBot + sLeft + sRight) / 4f

            val corner = (corner(l, t) + corner(r, t) + corner(l, b) + corner(r, b)) / 4f

            val area = (r - l).toLong() * (b - t).toLong()
            val density = if (area <= 0) 0f else inkInt.sum(l, t, r, b).toFloat() / area
            val content = contentScore(density)

            return cfg.wEdge * edgeSupport + cfg.wCorner * corner + cfg.wContent * content
        }

        private fun edgeSupport(border: Float, gutter: Float, page: Boolean): Float =
            maxOf(border, gutter, if (page) 1f else 0f)

        // Border coverage: fraction of the edge's row/column carrying a (dilated) line pixel.
        private fun hCov(l: Int, r: Int, y: Int): Float {
            val yy = y.coerceIn(0, h - 1)
            return hInt.sum(l, yy, r, yy + 1).toFloat() / (r - l).coerceAtLeast(1)
        }

        private fun vCov(t: Int, b: Int, x: Int): Float {
            val xx = x.coerceIn(0, w - 1)
            return vInt.sum(xx, t, xx + 1, b).toFloat() / (b - t).coerceAtLeast(1)
        }

        private fun density(x0: Int, y0: Int, x1: Int, y1: Int): Float {
            val a = (x1 - x0).toLong() * (y1 - y0).toLong()
            return if (a <= 0) 0f else inkInt.sum(x0, y0, x1, y1).toFloat() / a
        }

        // Gutter coverage: how blank the band just OUTSIDE the edge is.
        private fun gutterTop(l: Int, r: Int, t: Int) =
            if (t <= 0) 1f else 1f - density(l, t - gutterBand, r, t)

        private fun gutterBottom(l: Int, r: Int, b: Int) =
            if (b >= h) 1f else 1f - density(l, b, r, b + gutterBand)

        private fun gutterLeft(t: Int, b: Int, l: Int) =
            if (l <= 0) 1f else 1f - density(l - gutterBand, t, l, b)

        private fun gutterRight(t: Int, b: Int, r: Int) =
            if (r >= w) 1f else 1f - density(r, t, r + gutterBand, b)

        private fun corner(x: Int, y: Int): Float {
            if (x <= 1 || x >= w - 1 || y <= 1 || y >= h - 1) return 1f // page-boundary corner
            val hHit = hInt.sum(x - cornerWin, y - cornerWin, x + cornerWin, y + cornerWin) > 0
            val vHit = vInt.sum(x - cornerWin, y - cornerWin, x + cornerWin, y + cornerWin) > 0
            return if (hHit && vHit) 1f else if (hHit || vHit) 0.5f else 0f
        }

        private fun contentScore(d: Float): Float = when {
            d < cfg.contentMin -> (d / cfg.contentMin).coerceIn(0f, 1f)
            d > cfg.contentMax -> ((1f - d) / (1f - cfg.contentMax)).coerceIn(0f, 1f)
            else -> 1f
        }
    }

    companion object {
        private const val TAG = "PanelDetector"
    }
}
