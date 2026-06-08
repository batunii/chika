package com.chakra.comicreader

import android.app.Application
import android.util.Log
import com.chakra.comicreader.data.db.AppDatabase
import com.chakra.comicreader.data.library.LibraryRepository
import com.chakra.comicreader.detection.MlPanelDetector
import com.chakra.comicreader.detection.NoopPanelSource
import com.chakra.comicreader.detection.PanelDetector
import com.chakra.comicreader.detection.PanelSource
import org.opencv.android.OpenCVLoader

/**
 * Application entry point.
 *
 * Holds process-wide singletons (the Room database and the [LibraryRepository]) and initializes
 * OpenCV's native libraries once at startup via [OpenCVLoader.initLocal], which loads the bundled
 * `opencv_java4` shared object. If this fails, panel detection falls back to whole-page viewing.
 */
class ComicReaderApp : Application() {

    val database: AppDatabase by lazy { AppDatabase.get(this) }
    val libraryRepository: LibraryRepository by lazy {
        LibraryRepository(this, database.comicDao())
    }

    /**
     * Panel detector: prefer the on-device ML model; fall back to the classical CV detector if the
     * model can't load (and OpenCV is ready), or to whole-page-only as a last resort.
     */
    val panelSource: PanelSource by lazy {
        MlPanelDetector.tryCreate(this)
            ?: if (openCvReady) PanelDetector() else NoopPanelSource
    }

    var openCvReady: Boolean = false
        private set

    override fun onCreate() {
        super.onCreate()
        openCvReady = try {
            OpenCVLoader.initLocal()
        } catch (t: Throwable) {
            Log.e(TAG, "OpenCV init failed; panel detection disabled", t)
            false
        }
        Log.i(TAG, "OpenCV ready: $openCvReady")
    }

    companion object {
        private const val TAG = "ComicReaderApp"
    }
}
