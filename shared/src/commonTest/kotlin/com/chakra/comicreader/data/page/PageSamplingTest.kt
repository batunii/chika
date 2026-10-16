package com.chakra.comicreader.data.page

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PageSamplingTest {
    @Test fun smallOrEqualPagesAreNotSampled() {
        assertEquals(1, PageSampling.sampleSize(1500, 2560))
        assertEquals(1, PageSampling.sampleSize(2560, 2560))
    }

    @Test fun degenerateSizesAreNotSampled() {
        assertEquals(1, PageSampling.sampleSize(0, 2560))
        assertEquals(1, PageSampling.sampleSize(-5, 2560))
    }

    /** The rule keeps the long edge >= maxDim, so it lands in [maxDim, 2*maxDim). */
    @Test fun keepsLongEdgeAtOrAboveMaxDim() {
        assertEquals(1, PageSampling.sampleSize(5119, 2560))   // 5119 / 2 = 2559 < 2560
        assertEquals(2, PageSampling.sampleSize(5120, 2560))
        assertEquals(2, PageSampling.sampleSize(6000, 2560))
        assertEquals(4, PageSampling.sampleSize(10240, 2560))
        for (edge in listOf(2561, 3000, 4800, 5119, 5120, 9000, 20000)) {
            val decoded = edge / PageSampling.sampleSize(edge, 2560)
            assertTrue(decoded >= 2560 && decoded < 2 * 2560, "edge $edge decoded to $decoded")
        }
    }
}
