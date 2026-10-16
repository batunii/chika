package com.chakra.comicreader.data.archive

/**
 * A comic archive exposing its image pages in reading order.
 *
 * Implementations read from a local file (comics are imported/copied into app storage on add) so
 * that page access is random-access and cheap. Pages are returned as raw encoded bytes; decoding to
 * a bitmap is the platform page loader's job.
 */
interface ComicArchive : AutoCloseable {

    /** Number of image pages, after filtering out non-image entries and directories. */
    val pageCount: Int

    /** Raw encoded bytes (JPEG/PNG/WebP/…) of the page at [index]. */
    fun readPage(index: Int): ByteArray
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
