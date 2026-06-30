package com.chakra.comicreader.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import com.chakra.comicreader.R

/** Anton — the display face: wordmark, comic titles, badges, page numbers. */
val Anton = FontFamily(Font(R.font.anton_regular, FontWeight.Normal))

/** Archivo (variable) — UI labels, tags, body/metadata. Weights via font variation. */
val Archivo = FontFamily(
    archivoFont(FontWeight.Normal, 400),
    archivoFont(FontWeight.Medium, 500),
    archivoFont(FontWeight.SemiBold, 600),
    archivoFont(FontWeight.Bold, 700),
    archivoFont(FontWeight.ExtraBold, 800),
    archivoFont(FontWeight.Black, 900),
)

@OptIn(ExperimentalTextApi::class)
private fun archivoFont(weight: FontWeight, axis: Int): Font =
    Font(
        R.font.archivo_variable,
        weight = weight,
        variationSettings = FontVariation.Settings(FontVariation.weight(axis)),
    )

/** Base typography: Archivo everywhere by default; Anton is applied explicitly where it belongs. */
val ChikaTypography = Typography().run {
    copy(
        displayLarge = displayLarge.copy(fontFamily = Anton),
        displayMedium = displayMedium.copy(fontFamily = Anton),
        displaySmall = displaySmall.copy(fontFamily = Anton),
        headlineLarge = headlineLarge.copy(fontFamily = Anton),
        headlineMedium = headlineMedium.copy(fontFamily = Anton),
        headlineSmall = headlineSmall.copy(fontFamily = Anton),
        titleLarge = titleLarge.copy(fontFamily = Archivo, fontWeight = FontWeight.ExtraBold),
        titleMedium = titleMedium.copy(fontFamily = Archivo, fontWeight = FontWeight.Bold),
        titleSmall = titleSmall.copy(fontFamily = Archivo, fontWeight = FontWeight.Bold),
        bodyLarge = bodyLarge.copy(fontFamily = Archivo),
        bodyMedium = bodyMedium.copy(fontFamily = Archivo),
        bodySmall = bodySmall.copy(fontFamily = Archivo),
        labelLarge = labelLarge.copy(fontFamily = Archivo, fontWeight = FontWeight.Bold),
        labelMedium = labelMedium.copy(fontFamily = Archivo, fontWeight = FontWeight.Bold),
        labelSmall = labelSmall.copy(fontFamily = Archivo, fontWeight = FontWeight.SemiBold),
    )
}
