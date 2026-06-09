package com.chakra.comicreader.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A comic in the user's library. The archive is copied into app storage on import, so [filePath]
 * is a stable local path we fully control (the original picked file may become unreachable).
 * Reading progress is stored as [lastPage] + [lastSlot] so the reader resumes exactly where the
 * user left off, including which panel.
 */
@Entity(tableName = "comics")
data class ComicEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val title: String,
    val filePath: String,
    val coverPath: String?,
    val format: String,
    val pageCount: Int,
    val rightToLeft: Boolean = false,
    val lastPage: Int = 0,
    val lastSlot: Int = 0,
    val dateAdded: Long,
    val lastOpened: Long,
)
