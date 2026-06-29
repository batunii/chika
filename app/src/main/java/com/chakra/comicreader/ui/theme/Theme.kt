package com.chakra.comicreader.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * Chika is a dark, ink-grounded comic reader, so the theme is always the brand dark scheme
 * (no system light/dark switch). Material colors map onto the brand palette so stock components
 * pick up the identity; bespoke comic styling lives in the brand component kit.
 */
private val ChikaColorScheme = darkColorScheme(
    primary = Crimson,
    onPrimary = Cream,
    primaryContainer = Maroon,
    onPrimaryContainer = Cream,
    secondary = Ochre,
    onSecondary = Ink,
    secondaryContainer = Ochre,
    onSecondaryContainer = Ink,
    tertiary = CrimsonBright,
    onTertiary = Cream,
    background = Ink,
    onBackground = Cream,
    surface = Ink,
    onSurface = Cream,
    surfaceVariant = InkSoft,
    onSurfaceVariant = CreamMuted,
    outline = CreamMuted,
    error = CrimsonBright,
    onError = Cream,
)

/**
 * AMOLED variant: the ink grounds collapse to true black so OLED pixels switch fully off, while the
 * brand accents (crimson/ochre/cream) carry through unchanged.
 */
private val ChikaAmoledColorScheme = ChikaColorScheme.copy(
    background = Color.Black,
    surface = Color.Black,
    surfaceVariant = Color(0xFF101010),
)

@Composable
fun ComicReaderTheme(amoled: Boolean = false, content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (amoled) ChikaAmoledColorScheme else ChikaColorScheme,
        typography = ChikaTypography,
        content = content,
    )
}
