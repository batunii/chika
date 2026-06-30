package com.chakra.comicreader.detection

/**
 * Post-processes the ML model's panels into a nicer set of zoom regions:
 *
 *  - **Merge** runs of panels that are both *consecutive in reading order* and *spatially adjacent*
 *    when they're individually too small — so a strip of tiny panels becomes one comfortable zoom.
 *  - **Divide** oversized panels, using the panel's size *relative to the page*:
 *      - A panel **as wide as the page** but not tall → split into **2** side-by-side pieces.
 *      - A panel **as wide as the page and tall ("broad")** → split into **4** (a 2×2 grid).
 *      - A **double-page spread** (landscape image) with a panel spanning both pages → split at the
 *        page seam into two halves, then apply the 2/4 rule to each half → **up to 8** pieces.
 *      - Other big elongated panels keep the classic single cut (wide → vertical, tall → horizontal).
 *      - Square / normal panels are left as-is.
 *    Cuts are placed in the gap between speech-bubble groups when bubbles are available, else centred.
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
        /** Pixel aspect (w/h) within [low, high] counts as square → never divided (when not full-width). */
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
        // --- ratio-based division ---
        /** Panel width ≥ this fraction of the page ⇒ "as wide as the page". */
        val fullWidthFraction: Float = 0.85f,
        /** Panel height ≥ this fraction of the page ⇒ "broad" (split into 4 rather than 2). */
        val broadHeightFraction: Float = 0.55f,
        /** Don't split a full-width panel thinner than this (avoids slicing thin banners). */
        val minDivideHeightFraction: Float = 0.10f,
        /** Image aspect (w/h) ≥ this ⇒ treat the page image as a double-page spread. */
        val spreadAspectMin: Float = 1.4f,
        /** On a spread, a panel this wide (fraction of the image) is treated as spanning both pages. */
        val crossPageWidthFraction: Float = 0.85f,
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
            if (!region.merged && shouldDivide(p, pageAspect, config)) {
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

    /** Whether a (non-merged) panel should be split, and which rule applies, is decided here. */
    private fun shouldDivide(p: Panel, pageAspect: Float, c: Config): Boolean {
        if (isSpread(pageAspect, c) && isCrossPage(p, c)) return true
        if (isFullWidth(p, c) && p.height >= c.minDivideHeightFraction) return true
        return isBig(p, c) && !isSquare(p, pageAspect, c)
    }

    private fun divide(
        panel: Panel,
        bubbles: List<Panel>,
        pageAspect: Float,
        rightToLeft: Boolean,
        config: Config,
    ): List<Panel> {
        // Double-page spread: a panel spanning both pages is cut at the page seam (the panel's
        // centre), then each half is split by the 2/4 breadth rule → up to 8 pieces.
        if (isSpread(pageAspect, config) && isCrossPage(panel, config)) {
            val seam = panel.centerX
            val leftHalf = Panel(panel.left, panel.top, seam, panel.bottom)
            val rightHalf = Panel(seam, panel.top, panel.right, panel.bottom)
            val pagesInOrder = if (rightToLeft) listOf(rightHalf, leftHalf) else listOf(leftHalf, rightHalf)
            return pagesInOrder.flatMap { splitByBreadth(it, bubbles, rightToLeft, config) }
        }
        // A panel as wide as the page → 2 (just wide) or 4 (broad).
        if (isFullWidth(panel, config)) {
            return splitByBreadth(panel, bubbles, rightToLeft, config)
        }
        // Other big, elongated, non-square panels keep the classic single cut.
        return classicDivide(panel, bubbles, pageAspect, rightToLeft, config)
    }

    /** Full-width region → 4 pieces (2×2) if broad (tall too), else 2 pieces (side-by-side). */
    private fun splitByBreadth(panel: Panel, bubbles: List<Panel>, rtl: Boolean, config: Config): List<Panel> {
        val inside = bubblesInside(panel, bubbles)
        return if (panel.height >= config.broadHeightFraction) {
            quarter(panel, inside, rtl, config)
        } else {
            halveLeftRight(panel, inside, rtl, config)
        }
    }

    /** Two side-by-side pieces (one vertical, bubble-aware cut). */
    private fun halveLeftRight(panel: Panel, inside: List<Panel>, rtl: Boolean, config: Config): List<Panel> {
        val cut = cutPosition(inside.map { it.left }, inside.map { it.right }, panel.left, panel.right, config)
        val left = Panel(panel.left, panel.top, cut, panel.bottom)
        val right = Panel(cut, panel.top, panel.right, panel.bottom)
        return if (rtl) listOf(right, left) else listOf(left, right)
    }

    /** Four pieces in a 2×2 grid (one vertical + one horizontal, bubble-aware cut). */
    private fun quarter(panel: Panel, inside: List<Panel>, rtl: Boolean, config: Config): List<Panel> {
        val vCut = cutPosition(inside.map { it.left }, inside.map { it.right }, panel.left, panel.right, config)
        val hCut = cutPosition(inside.map { it.top }, inside.map { it.bottom }, panel.top, panel.bottom, config)
        val tl = Panel(panel.left, panel.top, vCut, hCut)
        val tr = Panel(vCut, panel.top, panel.right, hCut)
        val bl = Panel(panel.left, hCut, vCut, panel.bottom)
        val br = Panel(vCut, hCut, panel.right, panel.bottom)
        // Read each row in reading order, top row then bottom row.
        return if (rtl) listOf(tr, tl, br, bl) else listOf(tl, tr, bl, br)
    }

    /** The original behavior for big, elongated, non-full-width panels: one cut → 2 pieces. */
    private fun classicDivide(
        panel: Panel,
        bubbles: List<Panel>,
        pageAspect: Float,
        rtl: Boolean,
        config: Config,
    ): List<Panel> {
        val inside = bubblesInside(panel, bubbles)
        return if (realAspect(panel, pageAspect) >= config.squareAspectHigh) {
            halveLeftRight(panel, inside, rtl, config) // wide → vertical cut
        } else {
            val cut = cutPosition(inside.map { it.top }, inside.map { it.bottom }, panel.top, panel.bottom, config)
            listOf(
                Panel(panel.left, panel.top, panel.right, cut),
                Panel(panel.left, cut, panel.right, panel.bottom),
            ) // tall → horizontal cut
        }
    }

    private fun bubblesInside(panel: Panel, bubbles: List<Panel>): List<Panel> =
        bubbles.filter { it.centerX in panel.left..panel.right && it.centerY in panel.top..panel.bottom }

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
    private fun isFullWidth(p: Panel, c: Config) = p.width >= c.fullWidthFraction
    private fun isSpread(pageAspect: Float, c: Config) = pageAspect >= c.spreadAspectMin
    private fun isCrossPage(p: Panel, c: Config) = p.width >= c.crossPageWidthFraction

    private fun realAspect(p: Panel, pageAspect: Float): Float =
        if (p.height <= 0f) 1f else (p.width / p.height) * pageAspect

    private fun isSquare(p: Panel, pageAspect: Float, c: Config): Boolean {
        val a = realAspect(p, pageAspect)
        return a in c.squareAspectLow..c.squareAspectHigh
    }

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
