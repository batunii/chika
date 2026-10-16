package com.chakra.comicreader.data.archive

import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * Reads the stream fully, but refuses to buffer more than [max] bytes: a corrupt or hostile archive
 * entry that decompresses to gigabytes must fail the page, not OOM the app.
 */
internal fun InputStream.readBounded(max: Int): ByteArray {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (true) {
        val n = read(buffer)
        if (n < 0) break
        if (out.size() + n > max) throw PageTooLargeException("Page is larger than $max bytes")
        out.write(buffer, 0, n)
    }
    return out.toByteArray()
}
