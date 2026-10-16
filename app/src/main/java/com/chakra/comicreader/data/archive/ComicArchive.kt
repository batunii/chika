package com.chakra.comicreader.data.archive

/**
 * A comic archive exposing its image pages in reading order.
 *
 * Implementations read from a local file (comics are imported/copied into app storage on add) so
 * that page access is random-access and cheap. Pages are returned as raw encoded bytes; decoding to
 * a bitmap is the platform page loader's job. Page selection and ordering come from the shared
 * [ComicPages] so Android and iOS agree on what a page is and in which order they are read.
 */
interface ComicArchive : AutoCloseable {

    /** Number of image pages, after filtering out non-image entries and directories. */
    val pageCount: Int

    /** Raw encoded bytes (JPEG/PNG/WebP/…) of the page at [index]. */
    fun readPage(index: Int): ByteArray
}

/** Thrown when one archive entry is larger than the largest page we are willing to hold in memory. */
class PageTooLargeException(message: String) : java.io.IOException(message)
