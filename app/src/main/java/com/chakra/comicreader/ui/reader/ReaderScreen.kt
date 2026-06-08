package com.chakra.comicreader.ui.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector4D
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.TwoWayConverter
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.chakra.comicreader.detection.Panel
import kotlin.math.abs
import kotlin.math.roundToInt

private val PanelConverter = TwoWayConverter<Panel, AnimationVector4D>(
    convertToVector = { AnimationVector4D(it.left, it.top, it.right, it.bottom) },
    convertFromVector = { Panel(it.v1, it.v2, it.v3, it.v4) },
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(
    viewModel: ReaderViewModel,
    onBack: () -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var chromeVisible by remember { mutableStateOf(true) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        when {
            state.error != null -> ErrorView(state.error!!)
            state.page == null -> LoadingView()
            else -> PageViewer(
                state = state,
                onNext = viewModel::next,
                onPrev = viewModel::previous,
                onNextPage = viewModel::nextPage,
                onPrevPage = viewModel::previousPage,
                onToggleChrome = { chromeVisible = !chromeVisible },
            )
        }

        AnimatedVisibility(
            visible = chromeVisible,
            enter = slideInVertically { -it } + fadeIn(),
            exit = slideOutVertically { -it } + fadeOut(),
            modifier = Modifier.align(Alignment.TopCenter),
        ) {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            state.title,
                            maxLines = 1,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = pageStatus(state),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = viewModel::toggleReadingDirection) {
                        Icon(
                            Icons.Default.SwapHoriz,
                            contentDescription = if (state.rightToLeft) "Right-to-left" else "Left-to-right",
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
                ),
            )
        }

        AnimatedVisibility(
            visible = chromeVisible && state.pageCount > 1,
            enter = slideInVertically { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut(),
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            PageScrubber(
                pageIndex = state.pageIndex,
                pageCount = state.pageCount,
                onJumpToPage = viewModel::jumpToPage,
            )
        }
    }
}

@Composable
private fun PageScrubber(
    pageIndex: Int,
    pageCount: Int,
    onJumpToPage: (Int) -> Unit,
) {
    var scrubbing by remember { mutableStateOf(false) }
    var scrub by remember { mutableFloatStateOf(pageIndex.toFloat()) }
    LaunchedEffect(pageIndex) { if (!scrubbing) scrub = pageIndex.toFloat() }

    Surface(color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 6.dp),
        ) {
            Text(
                text = "Page ${(if (scrubbing) scrub.roundToInt() else pageIndex) + 1} / $pageCount",
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center,
            )
            Slider(
                value = scrub.coerceIn(0f, (pageCount - 1).toFloat()),
                onValueChange = { scrubbing = true; scrub = it },
                onValueChangeFinished = {
                    scrubbing = false
                    onJumpToPage(scrub.roundToInt())
                },
                valueRange = 0f..(pageCount - 1).toFloat(),
            )
        }
    }
}

@Composable
private fun PageViewer(
    state: ReaderUiState,
    onNext: () -> Unit,
    onPrev: () -> Unit,
    onNextPage: () -> Unit,
    onPrevPage: () -> Unit,
    onToggleChrome: () -> Unit,
) {
    val bitmap = state.page ?: return
    val image = remember(bitmap) { bitmap.asImageBitmap() }
    val rtl = state.rightToLeft

    val camera = remember { Animatable(state.currentCamera, PanelConverter) }
    LaunchedEffect(state.pageIndex, state.slot) {
        camera.animateTo(state.currentCamera, tween(360, easing = FastOutSlowInEasing))
    }

    val pageAlpha = remember { Animatable(1f) }
    LaunchedEffect(state.pageIndex) {
        pageAlpha.snapTo(0.35f)
        pageAlpha.animateTo(1f, tween(280))
    }

    // Free pinch-to-zoom / pan, reset whenever the framed view changes.
    var userScale by remember { mutableFloatStateOf(1f) }
    var userPanX by remember { mutableFloatStateOf(0f) }
    var userPanY by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(state.pageIndex, state.slot) {
        userScale = 1f; userPanX = 0f; userPanY = 0f
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            // Unified gesture: tap (panel/chrome), horizontal swipe (turn whole page), pinch (zoom).
            .pointerInput(rtl) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    var pan = Offset.Zero
                    var zoom = 1f
                    var maxPointers = 1
                    var pastSlop = false
                    val slop = viewConfiguration.touchSlop

                    do {
                        val event = awaitPointerEvent()
                        maxPointers = maxOf(maxPointers, event.changes.count { it.pressed })
                        val zoomChange = event.calculateZoom()
                        val panChange = event.calculatePan()
                        pan += panChange
                        zoom *= zoomChange
                        if (!pastSlop && (abs(zoom - 1f) > 0.02f || pan.getDistance() > slop)) {
                            pastSlop = true
                        }
                        if (pastSlop) {
                            // Apply zoom/pan only once zoomed in (otherwise the drag is a page swipe).
                            val newScale = (userScale * zoomChange).coerceIn(1f, 5f)
                            userScale = newScale
                            if (newScale > 1f) {
                                userPanX += panChange.x
                                userPanY += panChange.y
                            } else {
                                userPanX = 0f; userPanY = 0f
                            }
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                        }
                    } while (event.changes.any { it.pressed })

                    val w = size.width
                    when {
                        !pastSlop -> when { // a tap
                            down.position.x < w / 3f -> onPrev()
                            down.position.x > w * 2f / 3f -> onNext()
                            else -> onToggleChrome()
                        }
                        maxPointers == 1 && userScale <= 1.01f -> { // a single-finger swipe
                            val threshold = w * 0.15f
                            if (pan.x <= -threshold) { if (rtl) onPrevPage() else onNextPage() }
                            else if (pan.x >= threshold) { if (rtl) onNextPage() else onPrevPage() }
                        }
                    }
                }
            },
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val draw = computePageDraw(
                camera = camera.value,
                bitmapW = image.width,
                bitmapH = image.height,
                containerW = size.width,
                containerH = size.height,
            )
            val cx = size.width / 2f
            val cy = size.height / 2f
            val left = cx + (draw.left - cx) * userScale + userPanX
            val top = cy + (draw.top - cy) * userScale + userPanY
            val w = draw.scaledWidth * userScale
            val h = draw.scaledHeight * userScale

            drawImage(
                image = image,
                dstOffset = IntOffset(left.roundToInt(), top.roundToInt()),
                dstSize = IntSize(w.roundToInt(), h.roundToInt()),
                alpha = pageAlpha.value,
            )
        }
    }
}

@Composable
private fun LoadingView() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}

@Composable
private fun ErrorView(message: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Text(
            text = message,
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

private fun pageStatus(state: ReaderUiState): String {
    val page = "Page ${state.pageIndex + 1}/${state.pageCount}"
    val panel = state.panelLabel
    val panelText = when {
        state.detecting -> " · detecting…"
        panel != null -> " · panel $panel/${state.panels.size}"
        else -> " · full page"
    }
    return page + panelText
}
