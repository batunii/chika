package com.napkin.comicreader.data.archive

import org.apache.commons.compress.archivers.zip.ZipArchiveEntry
import org.apache.commons.compress.archivers.zip.ZipFile
import java.io.File

/**
 * CBZ (ZIP) archive backed by Apache Commons Compress, which supports random access to entries via
 * [ZipFile] and handles a wider range of ZIP encodings than the JDK's [java.util.zip.ZipFile].
 */
class ZipComicArchive(file: File) : ComicArchive {

    private val zip: ZipFile = ZipFile.builder().setFile(file).get()

    private val entries: List<ZipArchiveEntry> = buildList {
        val it = zip.entries
        while (it.hasMoreElements()) {
            val e = it.nextElement()
            if (!e.isDirectory && isImageEntry(e.name)) add(e)
        }
    }.sortedWith(compareBy(NaturalOrderComparator) { it.name })

    override val pageCount: Int get() = entries.size

    override fun readPage(index: Int): ByteArray =
        zip.getInputStream(entries[index]).use { it.readBytes() }

    override fun pageName(index: Int): String = entries[index].name

    override fun close() = zip.close()
}
