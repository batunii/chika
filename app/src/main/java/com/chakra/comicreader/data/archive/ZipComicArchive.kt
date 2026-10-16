package com.chakra.comicreader.data.archive

import com.chakra.comicreader.data.page.PageConstants
import org.apache.commons.compress.archivers.zip.ZipArchiveEntry
import org.apache.commons.compress.archivers.zip.ZipFile
import java.io.File

/**
 * CBZ (ZIP) archive backed by Apache Commons Compress, which supports random access to entries via
 * [ZipFile] and handles a wider range of ZIP encodings than the JDK's [java.util.zip.ZipFile].
 * Entries larger than [maxPageBytes] fail with [PageTooLargeException] instead of exhausting memory.
 */
class ZipComicArchive(
    file: File,
    private val maxPageBytes: Int = PageConstants.maxPageBytes,
) : ComicArchive {

    private val zip: ZipFile = ZipFile.builder().setFile(file).get()

    private val entries: List<ZipArchiveEntry> = run {
        val files = zip.entries.toList().filter { !it.isDirectory }
        ComicPages.orderedImageIndices(files.map { it.name }).map { files[it] }
    }

    override val pageCount: Int get() = entries.size

    override fun readPage(index: Int): ByteArray {
        val entry = entries[index]
        if (entry.size > maxPageBytes) {
            throw PageTooLargeException("Page ${index + 1} is ${entry.size} bytes (limit $maxPageBytes)")
        }
        // The declared size can lie (zip bombs), so the read itself is bounded too.
        return zip.getInputStream(entry).use { it.readBounded(maxPageBytes) }
    }

    override fun close() = zip.close()
}
