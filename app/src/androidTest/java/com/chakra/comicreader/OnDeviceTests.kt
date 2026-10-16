package com.chakra.comicreader

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.chakra.comicreader.data.archive.ComicArchiveFactory
import com.chakra.comicreader.data.archive.PageTooLargeException
import com.chakra.comicreader.data.archive.RarComicArchive
import com.chakra.comicreader.data.archive.RarToCbz
import com.chakra.comicreader.data.archive.ZipComicArchive
import com.chakra.comicreader.data.db.AppDatabase
import com.chakra.comicreader.data.library.LibraryRepository
import com.chakra.comicreader.data.page.PageLoader
import com.chakra.comicreader.data.settings.AppSettings
import com.chakra.comicreader.detection.MlPanelDetector
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Runs on a device/emulator: these exercise the native pieces JVM unit tests cannot load — the
 * 7-Zip library behind CBR support and the bundled TFLite panel model.
 *
 * Fixtures (androidTest assets) were built with `rar` (RAR5): pages "N.png" are N*10 px wide so a
 * decoded width identifies the page; `notes.txt` is not a page. `solid5.cbr` is a solid archive
 * created with the entries deliberately in non-reading order.
 */
@RunWith(AndroidJUnit4::class)
class OnDeviceTests {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private lateinit var dir: File

    @Before fun setUp() { dir = File(context.cacheDir, "ondevice").apply { deleteRecursively(); mkdirs() } }
    @After fun tearDown() { dir.deleteRecursively() }

    private fun asset(name: String): File = File(dir, name).also { out ->
        instrumentation.context.assets.open(name).use { i -> out.outputStream().use { i.copyTo(it) } }
    }

    private fun widthOf(bytes: ByteArray) =
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size).width

    private val expectedWidths = listOf(10, 20, 30, 100, 110) // pages 1,2,3,10,11 in natural order

    @Test fun rar5ArchiveOpensFiltersAndOrdersPages() {
        RarComicArchive(asset("rar5.cbr")).use { a ->
            assertEquals(5, a.pageCount)
            assertEquals(expectedWidths, (0 until 5).map { widthOf(a.readPage(it)) })
        }
    }

    @Test fun solidRarReturnsTheRightPageInAnyReadOrder() {
        RarComicArchive(asset("solid5.cbr")).use { a ->
            assertEquals(5, a.pageCount)
            // Random access into a solid archive is where decoders go wrong.
            for (i in listOf(4, 0, 3, 1, 2, 4, 0)) assertEquals(expectedWidths[i], widthOf(a.readPage(i)))
        }
    }

    @Test fun oversizedRarPageIsRejectedNotBuffered() {
        RarComicArchive(asset("rar5.cbr"), maxPageBytes = 100).use { a ->
            assertEquals(10, widthOf(a.readPage(0)))                       // small page: fine
            assertThrows(PageTooLargeException::class.java) { a.readPage(4) } // ~128 B page: over the cap
        }
    }

    @Test fun corruptRarThrowsAndDoesNotLeakFileHandles() {
        val junk = File(dir, "junk.cbr").apply { writeBytes(ByteArray(2048) { (it * 7).toByte() }) }
        fun openFds() = File("/proc/self/fd").list()?.size ?: 0
        val before = openFds()
        repeat(40) { assertThrows(Throwable::class.java) { RarComicArchive(junk).close() } }
        assertTrue("fd leak: $before -> ${openFds()}", openFds() - before < 10)
    }

    @Test fun rarToCbzProducesOrderedRandomAccessZipFromPlainAndSolidRars() {
        for (name in listOf("rar5.cbr", "solid5.cbr")) {
            val out = File(dir, "$name.cbz")
            RarToCbz.convert(asset(name), out)
            ZipComicArchive(out).use { a ->
                assertEquals(name, expectedWidths, (0 until a.pageCount).map { widthOf(a.readPage(it)) })
            }
        }
    }

    @Test fun rarToCbzRejectsOversizedPagesAndJunk() {
        assertThrows(Throwable::class.java) { RarToCbz.convert(asset("rar5.cbr"), File(dir, "o.cbz"), maxPageBytes = 100) }
        val junk = File(dir, "junk.cbr").apply { writeBytes(ByteArray(2048) { (it * 7).toByte() }) }
        assertThrows(Throwable::class.java) { RarToCbz.convert(junk, File(dir, "j.cbz")) }
    }

    @Test fun factoryRoutesCbrToTheRarBackend() {
        ComicArchiveFactory.open(asset("rar5.cbr")).use { assertEquals(5, it.pageCount) }
    }

    @Test fun importingARealCbrEndToEnd(): Unit = runBlocking {
        val db = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java).build()
        try {
            val repo = LibraryRepository(context, db.comicDao(), AppSettings(context))
            val id = repo.importComic(Uri.fromFile(asset("solid5.cbr"))).getOrThrow()
            val comic = repo.getComic(id)!!
            assertEquals(5, comic.pageCount)
            assertEquals("converted to CBZ at import", "CBZ", comic.format)
            assertTrue(comic.filePath.endsWith(".cbz"))
            ZipComicArchive(File(comic.filePath)).use { a ->
                assertEquals(expectedWidths, (0 until a.pageCount).map { widthOf(a.readPage(it)) })
            }
            assertNotNull(comic.coverPath)
            repo.deleteComic(id)
        } finally {
            db.close()
        }
    }

    /** The shipped model, run for real on a synthetic manga page (no copyrighted content). */
    @Test fun realModelDetectsValidOrderedPanels() {
        val detector = MlPanelDetector.tryCreate(context)
        assertNotNull("bundled model failed to load (see logcat MlPanelDetector)", detector)
        ZipComicArchive(asset("SyntheticManga.cbz")).use { archive ->
            val loader = PageLoader(archive)
            val bitmap = runBlocking { loader.loadPage(0) }
            for (rtl in listOf(false, true)) {
                val panels = detector!!.detect(bitmap, rtl)
                assertNotNull("inference failed", panels)
                assertTrue("expected at least a full-page region", panels!!.isNotEmpty())
                panels.forEach {
                    assertTrue("out of range: $it", it.left in 0f..1f && it.right in 0f..1f &&
                        it.top in 0f..1f && it.bottom in 0f..1f)
                    assertTrue("degenerate: $it", it.right > it.left && it.bottom > it.top)
                }
                assertFalse(panels.isEmpty())
            }
            loader.close()
        }
        detector!!.close()
    }

    @Test fun legacyRarComicsAreUpgradedToCbzInPlace(): Unit = runBlocking {
        val db = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java).build()
        val comicsDir = File(context.filesDir, "comics").apply { mkdirs() }
        val legacy = File(comicsDir, "legacy-${System.nanoTime()}.cbr").also { asset("solid5.cbr").copyTo(it, overwrite = true) }
        try {
            val repo = LibraryRepository(context, db.comicDao(), AppSettings(context))
            val id = db.comicDao().insert(
                com.chakra.comicreader.data.db.ComicEntity(
                    title = "Legacy", filePath = legacy.absolutePath, coverPath = null, format = "CBR",
                    pageCount = 5, dateAdded = 1, lastOpened = 1,
                ),
            )

            repo.upgradeLegacyCbr()

            val comic = repo.getComic(id)!!
            assertEquals("CBZ", comic.format)
            assertFalse("the raw RAR is gone", legacy.exists())
            ZipComicArchive(File(comic.filePath)).use { a ->
                assertEquals(expectedWidths, (0 until a.pageCount).map { widthOf(a.readPage(it)) })
            }
            File(comic.filePath).delete()
        } finally {
            legacy.delete()
            db.close()
        }
    }
}
