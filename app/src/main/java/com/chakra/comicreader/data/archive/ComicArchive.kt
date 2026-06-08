package com.chakra.comicreader.data.archive

import java.io.Closeable

/**
 * A comic archive exposing its image pages in reading order.
 *
 * Implementations read from a local [java.io.File] (comics are imported/copied into app storage
 * on add) so that page access is random-access and cheap. Pages are returned as raw encoded bytes;
 * decoding to a bitmap is the [com.chakra.comicreader.data.page.PageLoader]'s job.
 */
interface ComicArchive : Closeable {

    /** Number of image pages, after filtering out non-image entries and directories. */
    val pageCount: Int

    /** Raw encoded bytes (JPEG/PNG/WebP/…) of the page at [index]. */
    fun readPage(index: Int): ByteArray

    /** The archive entry name for [index], useful for debugging/logging. */
    fun pageName(index: Int): String
}

/** File extensions we treat as comic page images. */
private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "avif")

/** True if [name] looks like an image entry we should render as a page. */
fun isImageEntry(name: String): Boolean {
    val clean = name.substringAfterLast('/').substringAfterLast('\\')
    if (clean.startsWith(".") || clean.startsWith("__MACOSX")) return false
    val ext = clean.substringAfterLast('.', "").lowercase()
    return ext in IMAGE_EXTENSIONS
}
