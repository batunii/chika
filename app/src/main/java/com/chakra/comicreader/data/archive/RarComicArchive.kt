package com.chakra.comicreader.data.archive

import com.chakra.comicreader.data.page.PageConstants
import net.sf.sevenzipjbinding.ExtractOperationResult
import net.sf.sevenzipjbinding.IInArchive
import net.sf.sevenzipjbinding.ISequentialOutStream
import net.sf.sevenzipjbinding.PropID
import net.sf.sevenzipjbinding.SevenZip
import net.sf.sevenzipjbinding.impl.RandomAccessFileInStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

/**
 * CBR (RAR) archive backed by 7-Zip-JBinding.
 *
 * Unlike junrar (which only reads RAR4), 7-Zip's engine reads both **RAR4 and RAR5** — and RAR5 is
 * the modern default, so it's what most current `.cbr` files use. 7-Zip auto-detects the format
 * from the stream, so this also transparently handles `.cbr` files that are actually 7z/zip inside.
 *
 * The native 7-Zip library is bundled by the `7-Zip-JBinding-4Android` artifact and loaded lazily
 * on first [SevenZip.openInArchive] call.
 */
class RarComicArchive(
    file: File,
    private val maxPageBytes: Int = PageConstants.maxPageBytes,
) : ComicArchive {

    private val randomAccessFile = RandomAccessFile(file, "r")
    private val inArchive: IInArchive = try {
        SevenZip.openInArchive(null, RandomAccessFileInStream(randomAccessFile))
    } catch (t: Throwable) {
        // A corrupt archive must not leak the open file handle.
        runCatching { randomAccessFile.close() }
        throw t
    }

    /** (archiveItemIndex, path) for image entries, in reading order. */
    private val entries: List<Pair<Int, String>> = run {
        val files = (0 until inArchive.numberOfItems).mapNotNull { i ->
            val isFolder = inArchive.getProperty(i, PropID.IS_FOLDER) as? Boolean ?: false
            val path = inArchive.getProperty(i, PropID.PATH) as? String ?: return@mapNotNull null
            if (isFolder) null else i to path
        }
        ComicPages.orderedImageIndices(files.map { it.second }).map { files[it] }
    }

    override val pageCount: Int get() = entries.size

    override fun readPage(index: Int): ByteArray {
        val item = entries[index].first
        val declared = (inArchive.getProperty(item, PropID.SIZE) as? Number)?.toLong() ?: -1L
        if (declared > maxPageBytes) {
            throw PageTooLargeException("Page ${index + 1} is $declared bytes (limit $maxPageBytes)")
        }
        val out = ByteArrayOutputStream()
        var tooLarge = false
        val result = inArchive.extractSlow(item, ISequentialOutStream { data ->
            if (out.size() + data.size > maxPageBytes) {
                tooLarge = true
                0 // refuse the write: aborts the extraction instead of buffering a bomb
            } else {
                out.write(data)
                data.size
            }
        })
        if (tooLarge) throw PageTooLargeException("Page ${index + 1} exceeds $maxPageBytes bytes")
        if (result != ExtractOperationResult.OK) {
            throw IOException("Failed to extract page ${index + 1}: $result")
        }
        return out.toByteArray()
    }

    override fun close() {
        runCatching { inArchive.close() }
        runCatching { randomAccessFile.close() }
    }
}
