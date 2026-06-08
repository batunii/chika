package com.chakra.comicreader.data.archive

import java.io.File

enum class ComicFormat { CBZ, CBR, UNKNOWN }

/** Thrown when a file is neither a readable ZIP nor RAR comic archive. */
class UnsupportedComicException(message: String) : Exception(message)

/**
 * Opens a local comic [File] as a [ComicArchive], detecting the format by magic bytes (with the
 * file extension as a fallback). Magic-byte detection means a mislabeled ".cbz" that is really a
 * RAR (common in the wild) still opens correctly.
 */
object ComicArchiveFactory {

    private val ZIP_MAGIC = byteArrayOf(0x50, 0x4B, 0x03, 0x04)          // "PK\x03\x04"
    private val ZIP_EMPTY = byteArrayOf(0x50, 0x4B, 0x05, 0x06)          // empty archive
    private val RAR_MAGIC = byteArrayOf(0x52, 0x61, 0x72, 0x21, 0x1A, 0x07) // "Rar!\x1a\x07"

    fun detectFormat(file: File): ComicFormat {
        val head = ByteArray(8)
        val read = file.inputStream().use { it.read(head) }
        if (read >= 4 && (head.startsWith(ZIP_MAGIC) || head.startsWith(ZIP_EMPTY))) return ComicFormat.CBZ
        if (read >= 6 && head.startsWith(RAR_MAGIC)) return ComicFormat.CBR

        return when (file.extension.lowercase()) {
            "cbz", "zip" -> ComicFormat.CBZ
            "cbr", "rar" -> ComicFormat.CBR
            else -> ComicFormat.UNKNOWN
        }
    }

    fun open(file: File): ComicArchive = when (detectFormat(file)) {
        ComicFormat.CBZ -> ZipComicArchive(file)
        ComicFormat.CBR -> RarComicArchive(file)
        ComicFormat.UNKNOWN ->
            throw UnsupportedComicException("Not a CBZ or CBR archive: ${file.name}")
    }

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean {
        if (size < prefix.size) return false
        for (i in prefix.indices) if (this[i] != prefix[i]) return false
        return true
    }
}
