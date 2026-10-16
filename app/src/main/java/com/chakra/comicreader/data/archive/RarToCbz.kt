package com.chakra.comicreader.data.archive

import com.chakra.comicreader.data.page.PageConstants
import net.sf.sevenzipjbinding.ExtractAskMode
import net.sf.sevenzipjbinding.ExtractOperationResult
import net.sf.sevenzipjbinding.IArchiveExtractCallback
import net.sf.sevenzipjbinding.ISequentialOutStream
import net.sf.sevenzipjbinding.PropID
import net.sf.sevenzipjbinding.SevenZip
import net.sf.sevenzipjbinding.impl.RandomAccessFileInStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Repackages a CBR (RAR) as a CBZ once, at import.
 *
 * Reading a page out of a *solid* RAR with `extractSlow` re-decodes every earlier page in the solid
 * block, so page *i* costs O(i): measured on a 60-page solid archive, the last page took ~900 ms
 * (vs ~10 ms for a non-solid RAR) and reading every page in order took ~26 s (vs ~0.6 s). Extracting
 * all pages in ONE pass is linear, and the resulting ZIP has true random access — the same approach
 * the iOS app already uses. Pages are renamed to zero-padded reading order.
 */
object RarToCbz {

    /** Converts [rar] into [dest]. Throws (leaving [dest] possibly partial: callers delete it) on failure. */
    fun convert(rar: File, dest: File, maxPageBytes: Int = PageConstants.maxPageBytes) {
        val raf = RandomAccessFile(rar, "r")
        try {
            val archive = SevenZip.openInArchive(null, RandomAccessFileInStream(raf))
            try {
                val files = (0 until archive.numberOfItems).mapNotNull { i ->
                    val isFolder = archive.getProperty(i, PropID.IS_FOLDER) as? Boolean ?: false
                    val path = archive.getProperty(i, PropID.PATH) as? String ?: return@mapNotNull null
                    if (isFolder) null else i to path
                }
                val order = ComicPages.orderedImageIndices(files.map { it.second })
                if (order.isEmpty()) throw IOException("No image pages in archive")

                // archive item index -> zero-padded name in reading order
                val names = HashMap<Int, String>()
                order.forEachIndexed { rank, fileIdx ->
                    val (item, path) = files[fileIdx]
                    names[item] = "%05d.%s".format(rank, path.substringAfterLast('.', "jpg").lowercase())
                }
                // Ascending archive order = one sequential pass through a solid block.
                val items = names.keys.sorted().toIntArray()

                ZipOutputStream(BufferedOutputStream(FileOutputStream(dest))).use { zip ->
                    zip.setLevel(Deflater.NO_COMPRESSION) // pages are already-compressed images
                    val callback = Callback(zip, names, maxPageBytes)
                    archive.extract(items, false, callback)
                    callback.failure?.let { throw it }
                }
            } finally {
                runCatching { archive.close() }
            }
        } finally {
            runCatching { raf.close() }
        }
    }

    private class Callback(
        private val zip: ZipOutputStream,
        private val names: Map<Int, String>,
        private val maxPageBytes: Int,
    ) : IArchiveExtractCallback {
        var failure: Exception? = null
        private var written = 0L
        private var entryOpen = false

        // Exceptions must not cross the JNI boundary: record them and refuse further writes instead.
        override fun getStream(index: Int, mode: ExtractAskMode): ISequentialOutStream? {
            if (mode != ExtractAskMode.EXTRACT || failure != null) return null
            return try {
                zip.putNextEntry(ZipEntry(names.getValue(index)))
                entryOpen = true
                written = 0
                ISequentialOutStream { data ->
                    when {
                        failure != null -> 0
                        written + data.size > maxPageBytes -> {
                            failure = PageTooLargeException("Page exceeds $maxPageBytes bytes")
                            0
                        }
                        else -> try {
                            zip.write(data)
                            written += data.size
                            data.size
                        } catch (e: IOException) {
                            failure = e
                            0
                        }
                    }
                }
            } catch (e: IOException) {
                failure = e
                null
            }
        }

        override fun prepareOperation(mode: ExtractAskMode) = Unit

        override fun setOperationResult(result: ExtractOperationResult) {
            if (entryOpen) {
                runCatching { zip.closeEntry() }.onFailure { if (failure == null) failure = it as? Exception }
                entryOpen = false
            }
            if (result != ExtractOperationResult.OK && failure == null) {
                failure = IOException("Failed to extract a page: $result")
            }
        }

        override fun setTotal(total: Long) = Unit
        override fun setCompleted(complete: Long) = Unit
    }
}
