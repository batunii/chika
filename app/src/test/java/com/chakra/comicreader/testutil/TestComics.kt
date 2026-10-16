package com.chakra.comicreader.testutil

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Helpers that build real (tiny) comic archives for unit tests. */
object TestComics {

    /** A decodable PNG of the given size. */
    fun png(width: Int = 60, height: Int = 90): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            .toByteArray()
    }

    /** Bytes that carry an image extension but cannot be decoded. */
    val CORRUPT: ByteArray = "this is not an image".toByteArray()

    /** Writes a CBZ at [dir]/[name] with the given (entryName, bytes) pages. */
    fun cbz(dir: File, name: String, pages: List<Pair<String, ByteArray>>): File {
        val file = File(dir, name)
        ZipOutputStream(file.outputStream()).use { zip ->
            pages.forEach { (entry, bytes) ->
                zip.putNextEntry(ZipEntry(entry))
                zip.write(bytes)
                zip.closeEntry()
            }
        }
        return file
    }
}
