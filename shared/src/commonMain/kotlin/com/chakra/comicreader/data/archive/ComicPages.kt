package com.chakra.comicreader.data.archive

/** File extensions we treat as comic page images. */
private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "avif")

/** True if [name] looks like an image entry we should render as a page. */
fun isImageEntry(name: String): Boolean {
    val clean = name.substringAfterLast('/').substringAfterLast('\\')
    if (clean.startsWith(".") || clean.startsWith("__MACOSX")) return false
    val ext = clean.substringAfterLast('.', "").lowercase()
    return ext in IMAGE_EXTENSIONS
}

/** Page selection shared by every archive backend (Android Zip/Rar, iOS CBZ/CBR conversion). */
object ComicPages {
    /**
     * Indices into [names] of the entries that are pages, in reading order (natural filename order).
     * Callers pass only file entries (no directories); non-image entries are dropped here.
     */
    fun orderedImageIndices(names: List<String>): List<Int> =
        names.indices
            .filter { isImageEntry(names[it]) }
            .sortedWith(compareBy(NaturalOrderComparator) { names[it] })
}
