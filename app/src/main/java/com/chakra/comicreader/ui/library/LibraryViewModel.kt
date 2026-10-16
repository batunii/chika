package com.chakra.comicreader.ui.library

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.chakra.comicreader.ComicReaderApp
import com.chakra.comicreader.data.db.ComicEntity
import com.chakra.comicreader.data.library.LibraryRepository
import com.chakra.comicreader.data.settings.AppSettings
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class LibraryViewModel(
    private val repository: LibraryRepository,
    private val settings: AppSettings,
) : ViewModel() {

    val comics: StateFlow<List<ComicEntity>> = repository.comics
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    /** Global default reading direction applied to newly imported comics. */
    private val _defaultRightToLeft = MutableStateFlow(settings.defaultRightToLeft)
    val defaultRightToLeft: StateFlow<Boolean> = _defaultRightToLeft.asStateFlow()

    private val _importing = MutableStateFlow(false)
    val importing: StateFlow<Boolean> = _importing.asStateFlow()

    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()

    init {
        viewModelScope.launch {
            repository.pruneMissing()
            repository.upgradeLegacyCbr()
        }
    }

    private var activeImports = 0
    private val importJobs = mutableSetOf<Job>()

    fun importComic(uri: Uri) {
        val job = viewModelScope.launch {
            activeImports++
            _importing.value = true
            try {
                repository.importComic(uri).exceptionOrNull()?.let {
                    _message.value = it.message ?: "Import failed."
                }
            } finally {
                activeImports--
                _importing.value = activeImports > 0
            }
        }
        importJobs += job
        job.invokeOnCompletion { importJobs -= job }
    }

    /** Cancels any in-flight imports (the user tapped the spinner); partial files are cleaned up. */
    fun cancelImport() {
        importJobs.toList().forEach { it.cancel() }
    }

    fun deleteComic(id: Long) {
        viewModelScope.launch { repository.deleteComic(id) }
    }

    /** Flips the global default reading direction for comics imported from now on. */
    fun toggleDefaultDirection() {
        settings.defaultRightToLeft = !settings.defaultRightToLeft
        _defaultRightToLeft.value = settings.defaultRightToLeft
    }

    fun consumeMessage() {
        _message.value = null
    }

    companion object {
        fun factory(app: ComicReaderApp): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    LibraryViewModel(app.libraryRepository, app.settings) as T
            }
    }
}
