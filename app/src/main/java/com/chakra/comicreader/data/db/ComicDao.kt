package com.chakra.comicreader.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface ComicDao {

    @Query("SELECT * FROM comics ORDER BY lastOpened DESC")
    fun observeAll(): Flow<List<ComicEntity>>

    @Query("SELECT * FROM comics WHERE id = :id")
    suspend fun getById(id: Long): ComicEntity?

    @Insert
    suspend fun insert(comic: ComicEntity): Long

    @Query("UPDATE comics SET lastPage = :page, lastSlot = :slot, lastOpened = :openedAt WHERE id = :id")
    suspend fun updateProgress(id: Long, page: Int, slot: Int, openedAt: Long): Int

    @Query("UPDATE comics SET rightToLeft = :rtl WHERE id = :id")
    suspend fun updateReadingDirection(id: Long, rtl: Boolean): Int

    @Query("DELETE FROM comics WHERE id = :id")
    suspend fun delete(id: Long): Int
}
