package com.chakra.comicreader.data.page

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PageLoaderCacheTest {

    /** Pages decode up to ~70 MB; a budget below that makes a page evict itself from the cache. */
    @Test
    fun defaultCacheBudgetNeverDropsBelowTheFloor() {
        val budget = PageLoader.defaultCacheBytes()
        assertTrue("budget $budget below floor", budget >= PageConstants.cacheMinBytes)
        assertTrue("floor must hold at least one worst-case page", PageConstants.cacheMinBytes > 70 * 1024 * 1024)
    }

    @Test
    fun floorNeverExceedsTheHardCap() {
        assertEquals(true, PageConstants.cacheMinBytes <= PageConstants.cacheMaxBytes)
    }
}
