package com.chakra.comicreader.ui.brand

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.chakra.comicreader.ui.theme.Anton
import com.chakra.comicreader.ui.theme.Archivo
import com.chakra.comicreader.ui.theme.Cream
import com.chakra.comicreader.ui.theme.CreamMuted
import com.chakra.comicreader.ui.theme.Crimson
import com.chakra.comicreader.ui.theme.Ink
import com.chakra.comicreader.ui.theme.Ochre
import androidx.compose.material3.Text

/* ---- Signature texture & motifs ------------------------------------------------ */

/** Low-opacity halftone dot wash drawn behind content. Keep [alpha] subtle (0.05–0.22). */
fun Modifier.halftone(
    color: Color,
    alpha: Float = 0.06f,
    spacing: Dp = 9.dp,
    radius: Dp = 1.6.dp,
): Modifier = drawBehind {
    val sp = spacing.toPx()
    val r = radius.toPx()
    var y = 0f
    while (y < size.height + sp) {
        var x = 0f
        while (x < size.width + sp) {
            drawCircle(color = color, radius = r, center = Offset(x, y), alpha = alpha)
            x += sp
        }
        y += sp
    }
}

/** Hard offset comic shadow (no blur) drawn behind the element, peeking bottom-right. */
fun Modifier.comicShadow(
    offset: Dp = 5.dp,
    color: Color = Color(0xB3000000),
): Modifier = drawBehind {
    val o = offset.toPx()
    drawRect(color = color, topLeft = Offset(o, o), size = size)
}

/** The 20-point comic action-burst, as a clip shape. */
val StarburstShape: Shape = androidx.compose.foundation.shape.GenericShape { size, _ ->
    val pts = STARBURST_POINTS
    moveTo(pts[0] * size.width, pts[1] * size.height)
    var i = 2
    while (i < pts.size) {
        lineTo(pts[i] * size.width, pts[i + 1] * size.height)
        i += 2
    }
    close()
}

private val STARBURST_POINTS = floatArrayOf(
    0.50f, 0.00f, 0.60f, 0.16f, 0.78f, 0.09f, 0.74f, 0.28f, 0.95f, 0.30f,
    0.80f, 0.46f, 0.98f, 0.62f, 0.77f, 0.64f, 0.80f, 0.86f, 0.60f, 0.74f,
    0.52f, 0.96f, 0.42f, 0.75f, 0.22f, 0.88f, 0.23f, 0.65f, 0.02f, 0.64f,
    0.18f, 0.46f, 0.04f, 0.30f, 0.25f, 0.28f, 0.21f, 0.09f, 0.40f, 0.16f,
)

/** Four L-shaped reticle corner brackets, drawn as an overlay (use with fillMaxSize/matchParentSize). */
@Composable
fun Reticle(
    modifier: Modifier = Modifier,
    color: Color = Cream,
    inset: Dp = 8.dp,
    length: Dp = 14.dp,
    stroke: Dp = 2.5.dp,
) {
    Canvas(modifier) {
        val i = inset.toPx()
        val l = length.toPx()
        val s = stroke.toPx()
        val w = size.width
        val h = size.height
        fun l2(a: Offset, b: Offset) = drawLine(color, a, b, strokeWidth = s, cap = StrokeCap.Square)
        // top-left
        l2(Offset(i, i + l), Offset(i, i)); l2(Offset(i, i), Offset(i + l, i))
        // top-right
        l2(Offset(w - i - l, i), Offset(w - i, i)); l2(Offset(w - i, i), Offset(w - i, i + l))
        // bottom-left
        l2(Offset(i, h - i - l), Offset(i, h - i)); l2(Offset(i, h - i), Offset(i + l, h - i))
        // bottom-right
        l2(Offset(w - i - l, h - i), Offset(w - i, h - i)); l2(Offset(w - i, h - i), Offset(w - i, h - i - l))
    }
}

/* ---- Logo system --------------------------------------------------------------- */

/** "CHI·KA / CHITRA KATHA" lockup (cream + crimson Anton over an Archivo kicker). */
@Composable
fun ChikaWordmark(modifier: Modifier = Modifier) {
    Column(modifier) {
        Text(
            text = buildAnnotatedString {
                withStyle(SpanStyle(color = Cream)) { append("CHI") }
                withStyle(SpanStyle(color = Crimson)) { append("KA") }
            },
            fontFamily = Anton,
            fontSize = 28.sp,
        )
        Text(
            text = "CHITRA KATHA",
            fontFamily = Archivo,
            fontWeight = FontWeight.ExtraBold,
            fontSize = 8.5.sp,
            letterSpacing = 2.6.sp,
            color = CreamMuted,
            modifier = Modifier.padding(top = 3.dp),
        )
    }
}

/** The rotated ochre "kicker" banner (e.g. YOUR LIBRARY) with ink frame + hard shadow. */
@Composable
fun OchreBadge(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        fontFamily = Anton,
        fontSize = 15.sp,
        letterSpacing = 0.6.sp,
        color = Ink,
        modifier = modifier
            .graphicsLayer { rotationZ = -1.5f }
            .comicShadow(offset = 3.dp, color = Color(0x99000000))
            .background(Ochre, RoundedCornerShape(3.dp))
            .border(2.5.dp, Ink, RoundedCornerShape(3.dp))
            .padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

/** Ochre starburst page coin showing "page / total". */
@Composable
fun PageCoin(page: Int, total: Int, modifier: Modifier = Modifier, size: Dp = 58.dp) {
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(size)
                .clip(StarburstShape)
                .background(Ink),
        )
        Box(
            Modifier
                .size(size)
                .padding(3.dp)
                .clip(StarburstShape)
                .background(Ochre),
        )
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                "$page",
                fontFamily = Anton,
                fontSize = 20.sp,
                lineHeight = 16.sp,
                color = Ink,
            )
            Text(
                "$total",
                fontFamily = Anton,
                fontSize = 9.sp,
                lineHeight = 9.sp,
                color = Ink.copy(alpha = 0.75f),
                modifier = Modifier.offset(y = (-7).dp),
            )
        }
    }
}
