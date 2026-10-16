package com.chakra.comicreader.ui.reader

import android.content.Context
import android.graphics.Bitmap
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.chakra.comicreader.data.db.AppDatabase
import com.chakra.comicreader.data.db.ComicEntity
import com.chakra.comicreader.data.library.LibraryRepository
import com.chakra.comicreader.data.settings.AppSettings
import com.chakra.comicreader.detection.Panel
import com.chakra.comicreader.detection.PanelSource
import com.chakra.comicreader.testutil.TestComics
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Records how it was called; returns [panels] unless told to fail the first call. */
private class FakePanelSource(
    private val panels: List<Panel>,
    private val failFirstCall: Boolean = false,
) : PanelSource {
    val calls = AtomicInteger()
    val lastRtl = AtomicBoolean(false)

    override fun detect(page: Bitmap, rightToLeft: Boolean): List<Panel>? {
        lastRtl.set(rightToLeft)
        return if (failFirstCall && calls.incrementAndGet() == 1) null else {
            if (!failFirstCall) calls.incrementAndGet()
            panels
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class ReaderViewModelTest {

    private val threePanels = listOf(
        Panel(0f, 0f, 0.5f, 0.5f),
        Panel(0.5f, 0f, 1f, 0.5f),
        Panel(0f, 0.5f, 1f, 1f),
    )

    private lateinit var context: Context
    private lateinit var db: AppDatabase
    private lateinit var repo: LibraryRepository
    private lateinit var dir: File

    @Before
    fun setUp() {
        // viewModelScope runs on Main; run it inline so tests don't need a looper.
        Dispatchers.setMain(UnconfinedTestDispatcher())
        context = ApplicationProvider.getApplicationContext()
        db = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries().build()
        repo = LibraryRepository(context, db.comicDao(), AppSettings(context))
        dir = File(context.cacheDir, "reader-tests").apply { deleteRecursively(); mkdirs() }
    }

    @After
    fun tearDown() {
        db.close()
        Dispatchers.resetMain()
    }

    /** Inserts a comic backed by a real CBZ; [pages] are (entry name, bytes). */
    private fun comic(
        pages: List<Pair<String, ByteArray>>,
        lastPage: Int = 0,
        lastSlot: Int = 0,
        rtl: Boolean = false,
    ): Long = runBlocking {
        val file = TestComics.cbz(dir, "c${System.nanoTime()}.cbz", pages)
        db.comicDao().insert(
            ComicEntity(
                title = "T", filePath = file.absolutePath, coverPath = null, format = "CBZ",
                pageCount = pages.size, rightToLeft = rtl, lastPage = lastPage, lastSlot = lastSlot,
                dateAdded = 1, lastOpened = 1,
            ),
        )
    }

    private fun goodPages(n: Int) = (1..n).map { "%03d.png".format(it) to TestComics.png() }

    private fun vm(id: Long, source: PanelSource) = ReaderViewModel(id, repo, source)

    /** Polls the state (work happens on IO/Default threads) until [predicate] holds. */
    private fun ReaderViewModel.await(what: String, predicate: (ReaderUiState) -> Boolean): ReaderUiState {
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            state.value.let { if (predicate(it)) return it }
            Thread.sleep(20)
        }
        fail("timed out waiting for: $what (state=${state.value.copy(page = null)})")
        error("unreachable")
    }

    @Test
    fun opensAtSavedPageAndSlot() {
        val id = comic(goodPages(3), lastPage = 1, lastSlot = 2)
        val vm = vm(id, FakePanelSource(threePanels))

        val s = vm.await("page 1 loaded") { it.page != null && !it.loading && !it.detecting }

        assertEquals(1, s.pageIndex)
        assertEquals(2, s.slot)
        assertEquals(3, s.panels.size)
        assertEquals(3, s.pageCount)
    }

    @Test
    fun nextWalksIntroPanelsOutroThenTurnsPage() {
        val id = comic(goodPages(2))
        val vm = vm(id, FakePanelSource(threePanels))
        vm.await("page 0 loaded") { it.page != null && !it.detecting }

        // intro(0) -> panels(1..3) -> outro(4)
        repeat(4) { vm.next() }
        assertEquals(4, vm.state.value.slot)
        assertEquals(0, vm.state.value.pageIndex)

        vm.next() // past the outro: next page, at its intro
        val s = vm.await("page 1 shown") { it.pageIndex == 1 && !it.detecting && it.page != null }
        assertEquals(0, s.slot)
    }

    @Test
    fun previousFromIntroEntersPreviousPageAtItsOutro() {
        val id = comic(goodPages(2), lastPage = 1)
        val vm = vm(id, FakePanelSource(threePanels))
        vm.await("page 1 loaded") { it.pageIndex == 1 && it.page != null && !it.detecting }

        vm.previous()

        val s = vm.await("page 0 at outro") { it.pageIndex == 0 && !it.detecting && it.page != null }
        assertEquals(s.panels.size + 1, s.slot)
    }

    /** Regression: one undecodable page used to dead-end the reader (every nav call was blocked). */
    @Test
    fun corruptPageDoesNotStrandTheReader() {
        val pages = listOf(
            "001.png" to TestComics.png(),
            "002.png" to TestComics.png(),
            "003.png" to TestComics.CORRUPT,
            "004.png" to TestComics.png(),
        )
        val vm = vm(comic(pages, lastPage = 1), FakePanelSource(threePanels))
        vm.await("page 1 loaded") { it.pageIndex == 1 && it.page != null && !it.detecting }

        vm.nextPage() // onto the corrupt page
        val failed = vm.await("error on page 3") { it.error != null }
        assertEquals(2, failed.pageIndex)

        vm.next() // must step past it, not do nothing
        val past = vm.await("moved to page 4") { it.error == null && it.pageIndex == 3 && it.page != null }
        assertNull(past.error)

        // ...and the scrubber / previous work out of an error state too.
        vm.previousPage()
        vm.await("back on page 3") { it.pageIndex == 2 }
        vm.jumpToPage(0)
        assertEquals(0, vm.await("jumped to page 1") { it.pageIndex == 0 && it.error == null && it.page != null }.pageIndex)
    }

    @Test
    fun failedDetectionIsNotCachedAndRetriedOnNextVisit() {
        val source = FakePanelSource(threePanels, failFirstCall = true)
        val vm = vm(comic(goodPages(3)), source)

        // First detection fails: whole page, no panels invented.
        val first = vm.await("page 0 loaded") { it.page != null && !it.detecting }
        assertEquals(listOf(Panel.FULL_PAGE), first.panels)

        vm.nextPage()
        vm.await("page 1") { it.pageIndex == 1 && !it.detecting && it.page != null }
        vm.previousPage()

        // Back on page 0: detection ran again and succeeded (a cached failure would still be 1 panel).
        val again = vm.await("page 0 re-detected") { it.pageIndex == 0 && !it.detecting && it.panels.size == 3 }
        assertEquals(3, again.panels.size)
    }

    @Test
    fun toggleDirectionPersistsAndRedetectsWithNewDirection() {
        val source = FakePanelSource(threePanels)
        val id = comic(goodPages(2), rtl = false)
        val vm = vm(id, source)
        vm.await("loaded") { it.page != null && !it.detecting }
        assertFalse(source.lastRtl.get())

        vm.toggleReadingDirection()

        vm.await("rtl state") { it.rightToLeft && !it.detecting && it.page != null }
        assertTrue("detector must be asked for the new direction", source.lastRtl.get())
        val saved = runBlocking { repo.getComic(id) }
        assertNotNull(saved)
        assertTrue("direction is remembered per comic", saved!!.rightToLeft)
        assertEquals("toggle resets to the page intro", 0, vm.state.value.slot)
    }

    @Test
    fun missingComicReportsErrorInsteadOfCrashing() {
        val vm = vm(id = 9999, source = FakePanelSource(threePanels))

        val s = vm.await("error") { it.error != null }

        assertEquals("Comic not found.", s.error)
        vm.next(); vm.previous(); vm.nextPage(); vm.jumpToPage(3) // must all be harmless
        assertEquals(0, vm.state.value.pageCount)
    }
}
