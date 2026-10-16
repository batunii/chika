package com.chakra.comicreader.data.library

import android.content.Context
import android.net.Uri
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.chakra.comicreader.data.db.AppDatabase
import com.chakra.comicreader.data.db.ComicEntity
import com.chakra.comicreader.data.settings.AppSettings
import com.chakra.comicreader.testutil.TestComics
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class LibraryRepositoryTest {

    private lateinit var context: Context
    private lateinit var db: AppDatabase
    private lateinit var repo: LibraryRepository
    private lateinit var scratch: File

    private val comicsDir get() = File(context.filesDir, "comics")
    private val coversDir get() = File(context.filesDir, "covers")

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        db = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries().build()
        repo = LibraryRepository(context, db.comicDao(), AppSettings(context))
        scratch = File(context.cacheDir, "scratch").apply { deleteRecursively(); mkdirs() }
    }

    @After
    fun tearDown() {
        db.close()
        context.filesDir.deleteRecursively()
    }

    private fun threePageCbz() = TestComics.cbz(
        scratch, "book.cbz",
        listOf("001.png" to TestComics.png(), "002.png" to TestComics.png(), "003.png" to TestComics.png()),
    )

    private fun files(dir: File) = dir.listFiles()?.toList().orEmpty()

    @Test
    fun importValidCbzCopiesFileAndIndexesIt() = runBlocking {
        val result = repo.importComic(Uri.fromFile(threePageCbz()))

        assertTrue(result.exceptionOrNull()?.toString(), result.isSuccess)
        val comic = repo.getComic(result.getOrThrow())!!
        assertEquals(3, comic.pageCount)
        assertEquals("CBZ", comic.format)
        assertTrue("imported copy must exist", File(comic.filePath).exists())
        assertTrue("copy must live in app storage", File(comic.filePath).parentFile == comicsDir)
        assertNotNull(comic.coverPath)
        assertTrue(File(comic.coverPath!!).exists())
    }

    @Test
    fun importNonArchiveFailsAndLeavesNoFilesBehind() = runBlocking {
        val junk = File(scratch, "notes.txt").apply { writeText("definitely not an archive") }

        val result = repo.importComic(Uri.fromFile(junk))

        assertTrue(result.isFailure)
        assertTrue("no orphan comic copy", files(comicsDir).isEmpty())
        assertTrue("no orphan cover", files(coversDir).isEmpty())
        assertTrue(repo.comics.first().isEmpty())
    }

    @Test
    fun importArchiveWithNoImagesFailsAndCleansUp() = runBlocking {
        val empty = TestComics.cbz(scratch, "empty.cbz", listOf("readme.txt" to "hi".toByteArray()))

        val result = repo.importComic(Uri.fromFile(empty))

        assertTrue(result.isFailure)
        assertTrue(files(comicsDir).isEmpty())
        assertTrue(repo.comics.first().isEmpty())
    }

    @Test
    fun deleteRemovesRowAndFiles() = runBlocking {
        val id = repo.importComic(Uri.fromFile(threePageCbz())).getOrThrow()
        val comic = repo.getComic(id)!!

        repo.deleteComic(id)

        assertNull(repo.getComic(id))
        assertFalse(File(comic.filePath).exists())
        assertFalse(File(comic.coverPath!!).exists())
    }

    @Test
    fun pruneMissingDropsRowsWhoseFileIsGoneAndKeepsTheRest() = runBlocking {
        val keep = repo.importComic(Uri.fromFile(threePageCbz())).getOrThrow()
        // A restored-from-backup row: metadata present, archive absent.
        val ghost = db.comicDao().insert(
            ComicEntity(
                title = "Ghost", filePath = File(comicsDir, "gone.cbz").absolutePath, coverPath = null,
                format = "CBZ", pageCount = 10, dateAdded = 1, lastOpened = 1,
            ),
        )

        repo.pruneMissing()

        assertNotNull(repo.getComic(keep))
        assertNull(repo.getComic(ghost))
    }

    @Test
    fun saveProgressAndReadingDirectionPersist() = runBlocking {
        val id = repo.importComic(Uri.fromFile(threePageCbz())).getOrThrow()

        repo.saveProgress(id, page = 2, slot = 3)
        repo.setReadingDirection(id, rightToLeft = true)

        val comic = repo.getComic(id)!!
        assertEquals(2, comic.lastPage)
        assertEquals(3, comic.lastSlot)
        assertTrue(comic.rightToLeft)
    }

    /** A cancelled import must clean up its partial copy and propagate the cancellation. */
    @Test
    fun cancelledImportCleansUpAndPropagates() = runBlocking {
        val uri = Uri.parse("content://chika.test/big.cbz")
        lateinit var job: kotlinx.coroutines.Job
        var reads = 0
        val stream = object : java.io.InputStream() {
            override fun read(): Int = -1
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                reads++
                if (reads == 1) { // magic head: "PK\u0003\u0004" + padding
                    byteArrayOf(0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0).copyInto(b, off)
                    return 8
                }
                job.cancel() // user taps cancel mid-copy
                return minOf(len, 4096) // data keeps flowing; the loop must notice the cancellation
            }
        }
        org.robolectric.Shadows.shadowOf(context.contentResolver).registerInputStream(uri, stream)

        job = launch(kotlinx.coroutines.Dispatchers.Default) { repo.importComic(uri) }
        job.join()

        assertTrue("import was cancelled", job.isCancelled)
        assertTrue("no orphan comic copy", files(comicsDir).isEmpty())
        assertTrue("no orphan cover", files(coversDir).isEmpty())
        assertTrue(repo.comics.first().isEmpty())
    }
}
