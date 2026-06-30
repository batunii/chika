package com.chakra.comicreader.data.settings

import android.content.Context

/**
 * Lightweight app-wide preferences backed by [android.content.SharedPreferences].
 *
 * [defaultRightToLeft] is the reading direction applied to newly imported comics; each comic then
 * remembers its own direction once opened (stored per-comic in the database). This is the global
 * half of "remembered per comic + a global default", matching the iOS app's ReadingPrefs.
 */
class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("chika.settings", Context.MODE_PRIVATE)

    var defaultRightToLeft: Boolean
        get() = prefs.getBoolean(KEY_DEFAULT_RTL, false)
        set(value) { prefs.edit().putBoolean(KEY_DEFAULT_RTL, value).apply() }

    /** When true, the app uses a true-black (AMOLED) theme instead of the default ink dark. */
    var amoledTheme: Boolean
        get() = prefs.getBoolean(KEY_AMOLED, false)
        set(value) { prefs.edit().putBoolean(KEY_AMOLED, value).apply() }

    private companion object {
        const val KEY_DEFAULT_RTL = "default_rtl"
        const val KEY_AMOLED = "amoled_theme"
    }
}
