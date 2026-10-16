package com.chakra.comicreader.data.library

import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import com.chakra.comicreader.data.archive.ComicArchiveFactory
import com.chakra.comicreader.data.archive.ComicFormat
import com.chakra.comicreader.data.archive.ComicFormatDetector
import com.chakra.comicreader.data.archive.UnsupportedComicException
import com.chakra.comicreader.data.db.ComicDao
import com.chakra.comicreader.data.db.ComicEntity
import com.chakra.comicreader.data.settings.AppSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * Owns the comic library: importing files, listing them, tracking progress, and deleting them.
 *
 * Import copies the picked file into app-private storage ([Context.getFilesDir]) so the app has a
 * stable, randomly-accessible copy regardless of the original's lifetime or URI permissions. A
 * cover thumbnail is generated from the first page at import time so the library grid is cheap to
 * render.
 */
class LibraryRepository(
    private val context: Context,
    private val dao: ComicDao,
    private val settings: AppSettings,
) {
    val comics: Flow<List<ComicEntity>> = dao.observeAll()

    suspend fun getComic(id: Long): ComicEntity? = dao.getById(id)

    suspend fun saveProgress(id: Long, page: Int, slot: Int) =
        dao.updateProgress(id, page, slot, System.currentTimeMillis())

    suspend fun setReadingDirection(id: Long, rightToLeft: Boolean) =
        dao.updateReadingDirection(id, rightToLeft)

    /** Copies, validates, and indexes a picked comic. Returns the new row id, or an error. */
    suspend fun importComic(uri: Uri): Result<Long> = withContext(Dispatchers.IO) {
        val token = UUID.randomUUID().toString()
        val comicsDir = File(context.filesDir, "comics").apply { mkdirs() }
        val coversDir = File(context.filesDir, "covers").apply { mkdirs() }

        val displayName = queryDisplayName(uri) ?: "Comic"
        val ext = displayName.substringAfterLast('.', "").lowercase().ifEmpty { "cbz" }
        val title = displayName.substringBeforeLast('.', displayName)
        val dest = File(comicsDir, "$token.$ext")
        val coverFile = File(coversDir, "$token.jpg")

        try {
            // Peek the magic bytes before copying so a wrong pick (a multi-GB video, say) is
            // rejected without filling app storage first.
            var rejected = false
            val opened = context.contentResolver.openInputStream(uri)?.use { input ->
                val head = ByteArray(HEAD_BYTES)
                var n = 0
                while (n < head.size) {
                    val r = input.read(head, n, head.size - n)
                    if (r < 0) break
                    n += r
                }
                if (ComicFormatDetector.detect(head.copyOf(n), ext) == ComicFormat.UNKNOWN) {
                    rejected = true
                } else {
                    dest.outputStream().use { out ->
                        out.write(head, 0, n)
                        input.copyTo(out)
                    }
                }
                true
            } ?: false
            if (!opened) {
                return@withContext Result.failure(
                    UnsupportedComicException("Could not open the selected file."),
                )
            }
            if (rejected) {
                return@withContext Result.failure(
                    UnsupportedComicException("Not a CBZ or CBR file."),
                )
            }

            val format = ComicArchiveFactory.detectFormat(dest)
            if (format == ComicFormat.UNKNOWN) {
                dest.delete()
                return@withContext Result.failure(
                    UnsupportedComicException("Not a CBZ or CBR file."),
                )
            }

            val (pageCount, coverPath) = ComicArchiveFactory.open(dest).use { archive ->
                val count = archive.pageCount
                if (count == 0) return@use 0 to null
                val saved = runCatching { saveCover(archive.readPage(0), coverFile) }
                    .getOrDefault(false)
                count to coverFile.absolutePath.takeIf { saved }
            }

            if (pageCount == 0) {
                dest.delete()
                return@withContext Result.failure(
                    UnsupportedComicException("This archive has no readable pages."),
                )
            }

            val now = System.currentTimeMillis()
            val id = dao.insert(
                ComicEntity(
                    title = title,
                    filePath = dest.absolutePath,
                    coverPath = coverPath,
                    format = format.name,
                    pageCount = pageCount,
                    rightToLeft = settings.defaultRightToLeft,
                    dateAdded = now,
                    lastOpened = now,
                ),
            )
            Result.success(id)
        } catch (t: Throwable) {
            Log.e(TAG, "Import failed", t)
            dest.delete()
            coverFile.delete()
            Result.failure(t)
        }
    }

    suspend fun deleteComic(id: Long) = withContext(Dispatchers.IO) {
        val comic = dao.getById(id) ?: return@withContext
        // Row first: a kill between the steps leaves orphan files (harmless) instead of a library
        // entry whose file is gone.
        dao.delete(id)
        runCatching { File(comic.filePath).delete() }
        comic.coverPath?.let { runCatching { File(it).delete() } }
    }

    /**
     * Drops rows whose archive no longer exists — e.g. after a backup restore or device transfer,
     * which brings the database back without the (excluded) comic files.
     */
    suspend fun pruneMissing() = withContext(Dispatchers.IO) {
        comics.first()
            .filter { !File(it.filePath).exists() }
            .forEach { dao.delete(it.id) }
    }

    private fun saveCover(pageBytes: ByteArray, dest: File): Boolean {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(pageBytes, 0, pageBytes.size, bounds)
        val longEdge = maxOf(bounds.outWidth, bounds.outHeight)
        var sample = 1
        while (longEdge > 0 && longEdge / (sample * 2) >= COVER_MAX_DIMENSION) sample *= 2

        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        val bitmap = BitmapFactory.decodeByteArray(pageBytes, 0, pageBytes.size, opts)
            ?: return false
        return try {
            dest.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            true
        } finally {
            bitmap.recycle()
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        var cursor: Cursor? = null
        return try {
            cursor = context.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
            )
            if (cursor != null && cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) cursor.getString(idx) else null
            } else null
        } catch (t: Throwable) {
            null
        } finally {
            cursor?.close()
        }
    }

    companion object {
        private const val TAG = "LibraryRepository"
        private const val COVER_MAX_DIMENSION = 600
        private const val HEAD_BYTES = 8
    }
}
