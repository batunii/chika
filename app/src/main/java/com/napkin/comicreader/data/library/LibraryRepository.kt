package com.napkin.comicreader.data.library

import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import com.napkin.comicreader.data.archive.ComicArchiveFactory
import com.napkin.comicreader.data.archive.ComicFormat
import com.napkin.comicreader.data.archive.UnsupportedComicException
import com.napkin.comicreader.data.db.ComicDao
import com.napkin.comicreader.data.db.ComicEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
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

        try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { input.copyTo(it) }
            } ?: return@withContext Result.failure(
                UnsupportedComicException("Could not open the selected file."),
            )

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
                val coverFile = File(coversDir, "$token.jpg")
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
                    dateAdded = now,
                    lastOpened = now,
                ),
            )
            Result.success(id)
        } catch (t: Throwable) {
            Log.e(TAG, "Import failed", t)
            dest.delete()
            Result.failure(t)
        }
    }

    suspend fun deleteComic(id: Long) = withContext(Dispatchers.IO) {
        val comic = dao.getById(id) ?: return@withContext
        runCatching { File(comic.filePath).delete() }
        comic.coverPath?.let { runCatching { File(it).delete() } }
        dao.delete(id)
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
    }
}
