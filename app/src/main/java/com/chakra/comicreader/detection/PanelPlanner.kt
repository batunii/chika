package com.chakra.comicreader.detection

/**
 * Post-processes the ML model's panels into a nicer set of zoom regions:
 *
 *  - **Merge** runs of panels that are both *consecutive in reading order* and *spatially adjacent*
 *    when they're individually too small — so a strip of tiny panels becomes one comfortable zoom
 *    instead of several cramped ones. (6+7 may merge; 6+8 never, because they aren't consecutive.)
 *  - **Divide** a panel that's too big and clearly elongated: a wide panel gets one vertical cut, a
 *    tall panel one horizontal cut. The cut is placed in the gap between speech-bubble groups when
 *    bubbles are available, otherwise at the middle. Max two pieces.
 *  - **Square / normal** panels are left as-is (a big square is treated as a splash).
 *
 * Works in normalized `[0,1]` coordinates; real pixel aspect uses the page dimensions, since a
 * normalized square isn't a real square on a non-square page.
 */
object PanelPlanner {

    data class Config(
        /** Panel area (fraction of page) below which it's "small" → a merge candidate. */
        val smallAreaFraction: Float = 0.10f,
        /** Panel area (fraction of page) above which it's "big" → a divide candidate. */
        val bigAreaFraction: Float = 0.35f,
        /** Pixel aspect (w/h) within [low, high] counts as square → never divided. */
        val squareAspectLow: Float = 0.8f,
        val squareAspectHigh: Float = 1.25f,
        /** Max normalized gap between two panels for them to count as adjacent. */
        val adjacencyGap: Float = 0.05f,
        /** Min perpendicular overlap (fraction of the shorter side) for adjacency. */
        val adjacencyOverlap: Float = 0.4f,
        /** Hard cap on how many small panels merge into one zoom (readability). */
        val maxMergeCount: Int = 3,
        /** A merged group may not exceed these fractions of the page (keeps the zoom readable). */
        val maxMergedWidthFraction: Float = 0.55f,
        val maxMergedHeightFraction: Float = 0.45f,
        /** A divide cut must fall within this central band of the panel (avoids lopsided cuts). */
        val cutCentralMin: Float = 0.30f,
        val cutCentralMax: Float = 0.70f,
    )

    private data class Region(val panel: Panel, val merged: Boolean)

    /** Direction a merge run is growing in, so a group stays a single row or column (no L-shapes). */
    private enum class Dir { NONE, HORIZONTAL, VERTICAL }

    fun plan(
        ordered: List<Panel>,
        bubbles: List<Panel>,
        pageW: Int,
        pageH: Int,
        rightToLeft: Boolean,
        config: Config = Config(),
    ): List<Panel> {
        if (ordered.isEmpty()) return ordered
        val pageAspect = pageW.toFloat() / pageH.toFloat()

        val merged = mergeSmall(ordered, config)
        val result = ArrayList<Panel>(merged.size)
        for (region in merged) {
            val p = region.panel
            if (!region.merged && isBig(p, config) && !isSquare(p, pageAspect, config)) {
                result += divide(p, bubbles, pageAspect, rightToLeft, config)
            } else {
                result += p
            }
        }
        return result
    }

    private fun mergeSmall(ordered: List<Panel>, config: Config): List<Region> {
        val regions = ArrayList<Region>()
        var i = 0
        while (i < ordered.size) {
            val cur = ordered[i]
            if (!isSmall(cur, config)) {
                regions += Region(cur, merged = false)
                i++
                continue
            }
            // Grow a run of consecutive, adjacent, small panels — same direction only, and stop at
            // the count cap or when the merged region would get too big to read comfortably. The
            // outer loop resumes at the next panel, so an over-long run is chunked (e.g. 5 → 3 + 2).
            var union = cur
            var j = i
            var count = 1
            var dir = Dir.NONE
            while (j + 1 < ordered.size && count < config.maxMergeCount && isSmall(ordered[j + 1], config)) {
                val next = ordered[j + 1]
                val stepDir = adjacencyDir(ordered[j], next, config)
                if (stepDir == Dir.NONE) break
                if (dir == Dir.NONE) dir = stepDir else if (stepDir != dir) break
                val candidate = union(union, next)
                if (candidate.width > config.maxMergedWidthFraction ||
                    candidate.height > config.maxMergedHeightFraction
                ) break
                union = candidate
                j++
                count++
            }
            regions += Region(union, merged = count > 1)
            i = j + 1
        }
        return regions
    }

    private fun divide(
        panel: Panel,
        bubbles: List<Panel>,
        pageAspect: Float,
        rightToLeft: Boolean,
        config: Config,
    ): List<Panel> {
        val aspect = realAspect(panel, pageAspect)
        val inside = bubbles.filter {
            it.centerX in panel.left..panel.right && it.centerY in panel.top..panel.bottom
        }
        return if (aspect >= config.squareAspectHigh) {
            // Wide → vertical cut.
            val cut = cutPosition(
                lowEdges = inside.map { it.left }, highEdges = inside.map { it.right },
                start = panel.left, end = panel.right, config = config,
            )
            val left = Panel(panel.left, panel.top, cut, panel.bottom)
            val right = Panel(cut, panel.top, panel.right, panel.bottom)
            if (rightToLeft) listOf(right, left) else listOf(left, right)
        } else {
            // Tall → horizontal cut (top→bottom regardless of reading direction).
            val cut = cutPosition(
                lowEdges = inside.map { it.top }, highEdges = inside.map { it.bottom },
                start = panel.top, end = panel.bottom, config = config,
            )
            listOf(
                Panel(panel.left, panel.top, panel.right, cut),
                Panel(panel.left, cut, panel.right, panel.bottom),
            )
        }
    }

    /**
     * Picks the cut coordinate along an axis: the midpoint of the largest gap between consecutive
     * bubble spans, clamped to the central band; falls back to the centre when there's no usable gap.
     */
    private fun cutPosition(
        lowEdges: List<Float>,
        highEdges: List<Float>,
        start: Float,
        end: Float,
        config: Config,
    ): Float {
        val center = (start + end) / 2f
        val lo = start + (end - start) * config.cutCentralMin
        val hi = start + (end - start) * config.cutCentralMax

        if (lowEdges.size >= 2) {
            // Sort bubble spans by their low edge and find the widest gap between consecutive spans.
            val spans = lowEdges.indices.map { lowEdges[it] to highEdges[it] }.sortedBy { it.first }
            var bestGap = 0f
            var bestMid = center
            var cursor = spans.first().second
            for (k in 1 until spans.size) {
                val (nextLow, nextHigh) = spans[k]
                val gap = nextLow - cursor
                if (gap > bestGap) {
                    bestGap = gap
                    bestMid = (cursor + nextLow) / 2f
                }
                cursor = maxOf(cursor, nextHigh)
            }
            if (bestGap > 0f && bestMid in lo..hi) return bestMid
        }
        return center.coerceIn(lo, hi)
    }

    private fun isSmall(p: Panel, c: Config) = p.area < c.smallAreaFraction
    private fun isBig(p: Panel, c: Config) = p.area > c.bigAreaFraction
    private fun realAspect(p: Panel, pageAspect: Float): Float =
        if (p.height <= 0f) 1f else (p.width / p.height) * pageAspect

    private fun isSquare(p: Panel, pageAspect: Float, c: Config): Boolean {
        val a = realAspect(p, pageAspect)
        return a in c.squareAspectLow..c.squareAspectHigh
    }

    /** Whether two panels are adjacent and, if so, in which direction (row vs column). */
    private fun adjacencyDir(a: Panel, b: Panel, c: Config): Dir {
        val vOverlap = overlap(a.top, a.bottom, b.top, b.bottom) / minOf(a.height, b.height).coerceAtLeast(1e-4f)
        val hOverlap = overlap(a.left, a.right, b.left, b.right) / minOf(a.width, b.width).coerceAtLeast(1e-4f)
        val hGap = (maxOf(a.left, b.left) - minOf(a.right, b.right)).coerceAtLeast(0f)
        val vGap = (maxOf(a.top, b.top) - minOf(a.bottom, b.bottom)).coerceAtLeast(0f)
        val sideBySide = vOverlap >= c.adjacencyOverlap && hGap <= c.adjacencyGap
        val stacked = hOverlap >= c.adjacencyOverlap && vGap <= c.adjacencyGap
        return when {
            sideBySide && stacked -> if (hGap <= vGap) Dir.HORIZONTAL else Dir.VERTICAL
            sideBySide -> Dir.HORIZONTAL
            stacked -> Dir.VERTICAL
            else -> Dir.NONE
        }
    }

    private fun overlap(a0: Float, a1: Float, b0: Float, b1: Float): Float =
        (minOf(a1, b1) - maxOf(a0, b0)).coerceAtLeast(0f)

    private fun union(a: Panel, b: Panel): Panel =
        Panel(minOf(a.left, b.left), minOf(a.top, b.top), maxOf(a.right, b.right), maxOf(a.bottom, b.bottom))
}
