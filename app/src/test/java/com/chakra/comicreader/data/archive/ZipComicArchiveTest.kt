package com.chakra.comicreader.data.archive

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Plain-JVM tests: ZipComicArchive needs no Android classes. */
class ZipComicArchiveTest {
    private lateinit var dir: File

    @Before fun setUp() { dir = createTempDir("zip-archive-test") }
    @After fun tearDown() { dir.deleteRecursively() }

    private fun zip(vararg entries: Pair<String, ByteArray>): File {
        val f = File(dir, "t.cbz")
        ZipOutputStream(f.outputStream()).use { z ->
            entries.forEach { (n, b) -> z.putNextEntry(ZipEntry(n)); z.write(b); z.closeEntry() }
        }
        return f
    }

    @Test fun pagesAreFilteredAndNaturallyOrdered() {
        val a = byteArrayOf(1); val b = byteArrayOf(2); val c = byteArrayOf(3)
        ZipComicArchive(
            zip("10.png" to c, "docs/" to ByteArray(0), "notes.txt" to byteArrayOf(9), "2.png" to b, "1.png" to a),
        ).use { archive ->
            assertEquals(3, archive.pageCount)
            assertArrayEquals(a, archive.readPage(0))
            assertArrayEquals(b, archive.readPage(1))
            assertArrayEquals(c, archive.readPage(2))
        }
    }

    @Test fun oversizedEntryFailsInsteadOfBeingBuffered() {
        val small = ByteArray(100) { 1 }
        val big = ByteArray(5_000) { 2 }
        ZipComicArchive(zip("1.png" to small, "2.png" to big), maxPageBytes = 1_000).use { archive ->
            assertArrayEquals(small, archive.readPage(0))
            assertThrows(PageTooLargeException::class.java) { archive.readPage(1) }
        }
    }

    @Test fun readBoundedStopsAtTheLimitEvenWhenTheDeclaredSizeLies() {
        val stream = java.io.ByteArrayInputStream(ByteArray(10_000))
        assertThrows(PageTooLargeException::class.java) { stream.readBounded(1_000) }
        assertEquals(500, java.io.ByteArrayInputStream(ByteArray(500)).readBounded(1_000).size)
    }
}
