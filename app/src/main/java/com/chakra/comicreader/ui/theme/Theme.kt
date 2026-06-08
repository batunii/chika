package com.chakra.comicreader.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val DarkColors = darkColorScheme(
    primary = Color(0xFF9EC3FF),
    onPrimary = Color(0xFF00315C),
    secondary = Color(0xFFF2C14E),
    background = Color(0xFF101012),
    onBackground = Color(0xFFE7E7EC),
    surface = Color(0xFF1B1B1F),
    onSurface = Color(0xFFE7E7EC),
    surfaceVariant = Color(0xFF26262B),
)

private val LightColors = lightColorScheme(
    primary = Color(0xFF1F5FBF),
    secondary = Color(0xFFB07D1A),
    background = Color(0xFFFAFAFC),
    surface = Color(0xFFFFFFFF),
)

@Composable
fun ComicReaderTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = MaterialTheme.typography,
        content = content,
    )
}
