package com.chakra.comicreader.data.archive

import kotlin.test.Test
import kotlin.test.assertEquals

class ComicPagesTest {
    @Test fun dropsNonImagesAndOrdersNaturally() {
        val names = listOf("10.png", "notes.txt", "2.png", "1.png", "ComicInfo.xml")
        val order = ComicPages.orderedImageIndices(names)
        assertEquals(listOf("1.png", "2.png", "10.png"), order.map { names[it] })
    }

    @Test fun ordersAcrossFolders() {
        val names = listOf("ch10/01.jpg", "ch2/01.jpg", "ch2/02.jpg")
        assertEquals(listOf(1, 2, 0), ComicPages.orderedImageIndices(names))
    }

    @Test fun emptyAndNoImages() {
        assertEquals(emptyList(), ComicPages.orderedImageIndices(emptyList()))
        assertEquals(emptyList(), ComicPages.orderedImageIndices(listOf("a.txt", ".hidden.jpg")))
    }
}
