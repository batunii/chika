package com.chakra.comicreader.data.archive

/**
 * Compares strings so that embedded numbers sort numerically rather than lexicographically,
 * e.g. "page2" < "page10". Comic archives almost always name pages with un-padded numbers, so a
 * plain string sort would put page10 before page2. Comparison is case-insensitive.
 */
object NaturalOrderComparator : Comparator<String> {
    override fun compare(a: String, b: String): Int {
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            val ca = a[i]
            val cb = b[j]
            if (ca.isDigit() && cb.isDigit()) {
                // Gather full runs of digits and compare as numbers (ignoring leading zeros).
                val startA = i
                val startB = j
                while (i < a.length && a[i].isDigit()) i++
                while (j < b.length && b[j].isDigit()) j++
                val numA = a.substring(startA, i).trimStart('0').ifEmpty { "0" }
                val numB = b.substring(startB, j).trimStart('0').ifEmpty { "0" }
                if (numA.length != numB.length) return numA.length - numB.length
                val cmp = numA.compareTo(numB)
                if (cmp != 0) return cmp
            } else {
                val cmp = ca.lowercaseChar().compareTo(cb.lowercaseChar())
                if (cmp != 0) return cmp
                i++
                j++
            }
        }
        return (a.length - i) - (b.length - j)
    }
}
