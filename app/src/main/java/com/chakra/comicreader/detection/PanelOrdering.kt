package com.chakra.comicreader.detection

/**
 * Sorts detected panels into reading order.
 *
 * Comics are read in rows: top row first, then the next row down; within a row, left-to-right for
 * Western comics (or right-to-left for manga). The tricky part is deciding which panels share a
 * "row" when they are not perfectly aligned. We group panels whose vertical extents overlap by more
 * than [ROW_OVERLAP_RATIO] of the shorter panel's height, then order rows top→down and panels
 * within each row by horizontal position.
 */
object PanelOrdering {

    private const val ROW_OVERLAP_RATIO = 0.5f

    fun order(panels: List<Panel>, rightToLeft: Boolean = false): List<Panel> {
        if (panels.size <= 1) return panels

        val byTop = panels.sortedBy { it.top }
        val rows = mutableListOf<MutableList<Panel>>()
        for (panel in byTop) {
            val row = rows.lastOrNull()
            if (row != null && row.any { verticalOverlapRatio(it, panel) >= ROW_OVERLAP_RATIO }) {
                row.add(panel)
            } else {
                rows.add(mutableListOf(panel))
            }
        }

        return rows
            .sortedBy { row -> row.minOf { it.top } }
            .flatMap { row ->
                if (rightToLeft) row.sortedByDescending { it.left }
                else row.sortedBy { it.left }
            }
    }

    /** Fraction of the shorter panel's height that the two panels' vertical ranges share. */
    private fun verticalOverlapRatio(a: Panel, b: Panel): Float {
        val overlap = (minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)).coerceAtLeast(0f)
        val shorter = minOf(a.height, b.height).coerceAtLeast(1e-4f)
        return overlap / shorter
    }
}
