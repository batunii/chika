import SwiftUI
import ChikaShared

/// Panel-by-panel CBZ reader with Chika chrome: a branded header (back + title + issue), reticle
/// brackets framing the page, the starburst page coin, and a "tap to step" hint — matching the
/// Android reader. Tapping the right side steps page → panel 1 → … → next page; the left side steps
/// back; panels come from the on-device Core ML detector via the shared decoder + planner, and the
/// camera is framed by the shared computePageDraw.
struct ReaderView: View {
    let comicURL: URL

    private enum LoadState {
        case loading
        case failed(String)
        case ready(PageLoader)
    }

    private static let detector = LiteRTPanelDetector()
    private static let ioQueue = DispatchQueue(label: "chika.reader.io", qos: .userInitiated)
    private static let detectQueue = DispatchQueue(label: "chika.reader.detect", qos: .userInitiated)

    // Flick tuning ported from Android's ReaderScreen: a page turn needs a genuine horizontal flick
    // (velocity, not distance), biased against vertical drags, so a slow reposition doesn't turn.
    private static let flickVelocityPxS: CGFloat = 700  // Android FLICK_VELOCITY_PX_S
    private static let swipeHorizontalBias: CGFloat = 1.2 // Android SWIPE_HORIZONTAL_BIAS
    // Sentinel restoreStep meaning "land on this page's whole-page outro" (used by backward turns);
    // resolved to regions.count once the page's regions are known.
    private static let outroSlot = Int.max
    // Android's camera motion: tween(360, FastOutSlowInEasing) between framed views, and
    // tween(240) for the double-tap recenter. FastOutSlowIn == cubic-bezier(0.4, 0, 0.2, 1).
    private static let cameraTween = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.36)
    private static let recenterTween = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.24)

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: ChikaSettings
    @State private var state: LoadState = .loading
    @State private var page = 0
    @State private var pageCount = 1
    @State private var image: UIImage?
    @State private var regions: [Panel] = [Panel.companion.FULL_PAGE]
    @State private var step = -1
    @State private var detecting = false
    @State private var rightToLeft = false
    @State private var showChrome = true
    @State private var loadToken = 0
    // Detected panels cached per page (in the current reading direction) so back/forward and
    // prefetched pages don't re-run the detector. Cleared when the direction changes.
    @State private var panelCache: [Int: [Panel]] = [:]
    // Manual zoom/pan layered on top of the panel-framing camera (pinch to zoom, drag to pan).
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var steadyPan: CGSize = .zero
    // Page scrubber state (commit on release, not per-tick) + per-page fade-in alpha.
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @State private var pageAlpha: Double = 1

    private var title: String { comicURL.deletingPathExtension().lastPathComponent }
    // Slot model matching Android: step -1 = whole-page intro, 0…n-1 = panels, n = whole-page outro.
    // The intro and outro both frame the whole page, so page turns always land zoomed-out.
    private var camera: Panel {
        (step >= 0 && step < regions.count) ? regions[step] : Panel.companion.FULL_PAGE
    }
    // Whether the current slot is a framed panel (vs. the whole-page intro/outro).
    private var onPanel: Bool { step >= 0 && step < regions.count }

    private var isReady: Bool { if case .ready = state { return true }; return false }

    // Actual size handed to the page Canvas, captured from the live layout. TEMP diagnostic state
    // (remove with the overlay below once device framing is confirmed).
    @State private var canvasBox: CGSize = .zero

    var body: some View {
        // Only the page canvas escapes the safe area (full-bleed, origin-0, like Android's
        // full-window reader). The chrome stays in the normal safe-area layout, so SwiftUI itself
        // keeps the top bar below the notch and the scrubber above the home indicator — no manual
        // inset math. (An earlier version put .ignoresSafeArea() on a root GeometryReader and read
        // proxy.safeAreaInsets for the chrome padding — but ignoring the safe area zeroes those
        // insets, which shoved the title under the status bar and the slider under the home bar.)
        ZStack {
            settings.ground.ignoresSafeArea()
            switch state {
            case .loading:
                ProgressView().tint(Chika.ochre)
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(Chika.ochre)
                    Text(message).font(.archivo(14)).foregroundColor(Chika.cream)
                        .multilineTextAlignment(.center)
                }
                .padding()
            case .ready(let loader):
                GeometryReader { screen in
                    readerBody(loader, size: screen.size)
                        .onAppear { canvasBox = screen.size }
                        .onChange(of: screen.size) { canvasBox = $0 }
                }
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            if showChrome && isReady {
                topBar.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showChrome && isReady && pageCount > 1 {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // TEMP diagnostic (remove once device framing is confirmed): the size the Canvas really
        // gets plus the live zoom/pan, so one device screenshot pins any remaining divergence.
        .overlay(alignment: .topLeading) {
            Text(String(format: "cvs %.0f×%.0f · z %.2f · p %.0f/%.0f",
                        canvasBox.width, canvasBox.height, zoom, pan.width, pan.height))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.green)
                .padding(3).background(Color.black.opacity(0.55))
                .padding(.top, 2).padding(.leading, 3)
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showChrome)
        .task { load() }
    }

    private func load() {
        do {
            let archive = try CbzArchive(url: comicURL)
            let loader = PageLoader(archive: archive)
            guard loader.pageCount > 0 else { state = .failed("No image pages found in this archive"); return }
            pageCount = loader.pageCount
            // Reading direction: this comic's saved choice, or the global default if never set.
            rightToLeft = ReadingProgress.readingDirection(comicURL)
            // QA hook: force a direction at launch (never set in production).
            if let r = ProcessInfo.processInfo.environment["CHIKA_DEBUG_RTL"] { rightToLeft = (r == "1") }
            // Resume where we left off (page and panel), clamped to the current page count.
            if let saved = ReadingProgress.get(comicURL) {
                page = min(max(saved.page, 0), pageCount - 1)
            }
            // QA hook: jump straight to a page (never set in production).
            if let p = ProcessInfo.processInfo.environment["CHIKA_DEBUG_PAGE"], let pi = Int(p) {
                page = min(max(pi, 0), pageCount - 1)
            }
            state = .ready(loader)
            ReadingProgress.markOpened(comicURL)   // bump recency so it sorts to the top of the library
            // QA hook: start on a specific panel index (never set in production).
            var restore = ReadingProgress.get(comicURL)?.step ?? -1
            if let s = ProcessInfo.processInfo.environment["CHIKA_DEBUG_STEP"], let si = Int(s) { restore = si }
            loadPage(loader, restoreStep: restore)
        } catch {
            state = .failed("Could not open archive: \(error.localizedDescription)")
        }
    }

    /// Loads a page's image OFF the main thread. Reading + decoding a multi-MB page on the main
    /// thread (e.g. on every slider tick while scrubbing) blocks the UI and gets the app killed by
    /// the watchdog. A serial queue avoids concurrent ZIP reads (ZIPFoundation isn't thread-safe),
    /// and a token ensures only the latest page renders when scrubbing fast.
    private func loadPage(_ loader: PageLoader, restoreStep: Int = -1) {
        regions = panelCache[page] ?? [Panel.companion.FULL_PAGE]
        // Resolve the outro sentinel now that this page's regions are known (backward page turns
        // land on the whole-page outro, matching Android).
        step = (restoreStep == Self.outroSlot) ? regions.count : restoreStep
        resetZoom()
        persist()
        pageAlpha = 0.35   // fades up to 1 once the page renders (Android's 280ms page fade-in)

        loadToken &+= 1
        let token = loadToken
        let target = page
        Self.ioQueue.async {
            let img = loader.loadPage(target) // downsampled + LRU-cached
            DispatchQueue.main.async {
                guard token == self.loadToken else { return } // a newer load superseded this one
                self.image = img
                withAnimation(.easeOut(duration: 0.28)) { self.pageAlpha = 1 }
                if let cached = self.panelCache[target] {
                    withAnimation(Self.cameraTween) {   // land on the restored slot with the camera tween
                        self.regions = cached
                        // Keep intro (-1) / outro (count) as whole-page; clamp only strays past the outro.
                        if self.step > cached.count { self.step = cached.count }
                    }
                } else {
                    self.redetect()
                }
                self.prefetch(target + 1, loader)
            }
        }
    }

    private func resetZoom() {
        zoom = 1; steadyZoom = 1; pan = .zero; steadyPan = .zero
    }

    /// Turns a whole page (resetting to the page view). [next] is reading-forward; RTL is handled
    /// by the caller mirroring the swipe direction.
    private func turnPage(next: Bool, in loader: PageLoader) {
        let target = page + (next ? 1 : -1)
        guard target >= 0, target < loader.pageCount else { return }
        page = target
        loadPage(loader)
    }

    private func persist() {
        ReadingProgress.set(comicURL, page: page, step: step, total: pageCount, rtl: rightToLeft)
    }

    private func redetect() {
        guard let img = image, let detector = Self.detector else { return }
        let rtl = rightToLeft
        let forPage = page
        detecting = true
        // Serial queue + page guard: scrubbing fast enqueues detections instead of running them
        // concurrently (the interpreter lock would otherwise just back up threads), and stale
        // results for a page we've already left are discarded.
        Self.detectQueue.async {
            let found = detector.zoomRegions(for: img, rightToLeft: rtl)
            DispatchQueue.main.async {
                self.panelCache[forPage] = found
                guard forPage == self.page else { return }
                withAnimation(Self.cameraTween) {   // glide into the framed panel when detection lands
                    self.regions = found
                    if self.step > found.count { self.step = found.count } // keep intro/outro/panel in range
                }
                self.detecting = false
            }
        }
    }

    /// Warms the next page in the background — decode (LRU-cached) + detect (panel-cached) — so
    /// stepping onto it is instant instead of stalling on a multi-MB decode + inference.
    private func prefetch(_ index: Int, _ loader: PageLoader) {
        guard index >= 0, index < loader.pageCount, panelCache[index] == nil,
              let detector = Self.detector else { return }
        let rtl = rightToLeft
        Self.detectQueue.async {
            guard let img = loader.loadPage(index) else { return }
            let found = detector.zoomRegions(for: img, rightToLeft: rtl)
            DispatchQueue.main.async {
                guard self.rightToLeft == rtl else { return } // direction changed; cache would be stale
                self.panelCache[index] = found
            }
        }
    }

    @ViewBuilder
    private func readerBody(_ loader: PageLoader, size: CGSize) -> some View {
        // `size` is the true full screen (from the GeometryReader that ignores the safe area), so
        // the page is framed in the exact origin-0 full-screen container the sim/Android assume.
        // The page is a plain Image carried by one animatable transform (CameraFraming) that runs
        // the shared computePageDraw per frame — so stepping between panels TWEENS the camera the
        // way Android's Animatable camera does (a Canvas can't animate; it jump-cuts).
        ZStack(alignment: .topLeading) {
            if let image, let cg = image.cgImage {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: CGFloat(cg.width), height: CGFloat(cg.height))
                    .modifier(CameraFraming(
                        camL: CGFloat(camera.left), camT: CGFloat(camera.top),
                        camR: CGFloat(camera.right), camB: CGFloat(camera.bottom),
                        zoom: zoom, panX: pan.width, panY: pan.height,
                        container: size))
                    .opacity(pageAlpha)
            }
        }
        // topLeading alignment is load-bearing: the bitmap-sized Image makes the ZStack oversized,
        // and a default (.center) frame alignment would shift the image's local origin — the
        // CameraFraming transform assumes local (0,0) sits at the container's top-left corner.
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .overlay { if image == nil { ProgressView().tint(Chika.ochre) } }
        // Reticle framing brackets — always drawn while reading (independent of chrome), crimson.
        .overlay { if image != nil {
            Reticle(color: Chika.crimson.opacity(0.45), inset: 6, length: 16, stroke: 2).padding(6)
        } }
        // UIKit gesture layer: pinch to zoom (1×–5×), pan when zoomed, tap zones, double-tap to
        // recenter, and a velocity flick to turn pages — all recognized simultaneously.
        .overlay {
            ReaderGestures(
                onTap: { location, sz in tapZone(x: location.x, width: sz.width, in: loader) },
                onDoubleTap: { withAnimation(Self.recenterTween) { resetZoom() } },
                onPinchChanged: { scale in zoom = min(max(steadyZoom * scale, 1), 5) },
                onPinchEnded: { if zoom <= 1.01 { resetZoom() } else { steadyZoom = zoom } },
                onPanChanged: { t in
                    // The comic floats over the background, clamped so it can't be lost off-screen.
                    let raw = CGSize(width: steadyPan.width + t.width, height: steadyPan.height + t.height)
                    pan = clampPan(raw, viewSize: size)
                },
                onPanEnded: { _, velocity, maxTouches in
                    endPan(velocity: velocity, maxTouches: maxTouches, in: loader)
                }
            )
        }
    }

    // Top-bar status line, matching Android: "Page X/Y · panel N/M" / "· full page" / "· detecting…".
    private var pageStatus: String {
        let prefix = "Page \(page + 1)/\(pageCount) · "
        if detecting { return prefix + "detecting…" }
        if onPanel { return prefix + "panel \(step + 1)/\(regions.count)" }
        return prefix + "full page"
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Chika.cream)
                    .frame(width: 38, height: 38)
                    .background(Chika.cream.opacity(0.12))
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.archivo(14, weight: 800)).foregroundColor(Chika.cream).lineLimit(1)
                Text(pageStatus).font(.archivo(9)).tracking(1.4).foregroundColor(Chika.creamMuted)
            }
            Spacer()
            // Show whole page (Android's ZoomOutMap): plain icon, always enabled (no-op on full page).
            Button { showWholePage() } label: {   // showWholePage runs its own camera tween
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Chika.cream)
                    .frame(width: 38, height: 38)
            }
            DirectionChip(rightToLeft: rightToLeft) {
                rightToLeft.toggle()
                panelCache.removeAll() // panels are ordered per-direction; re-detect under the new one
                persist(); redetect()
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.top, 8).padding(.bottom, 18)
        // The bar itself sits in the safe area; only its scrim bleeds up behind the status bar.
        .background(LinearGradient(colors: [Chika.ink.opacity(0.94), .clear],
                                   startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top))
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SWIPE TO TURN").font(.anton(12)).tracking(2).foregroundColor(Chika.creamMuted)
                Spacer()
                PageCoin(page: (scrubbing ? Int(scrub.rounded()) : page) + 1, total: pageCount)
            }
            Slider(
                value: $scrub,
                in: 0...Double(max(pageCount - 1, 1)),
                onEditingChanged: { editing in
                    if editing { scrubbing = true }
                    else {
                        scrubbing = false
                        page = Int(scrub.rounded())
                        if case .ready(let a) = state { loadPage(a) }
                    }
                }
            )
            .tint(Chika.ochre)
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
        // The scrubber sits in the safe area; only its scrim bleeds down behind the home indicator.
        .background(LinearGradient(colors: [.clear, Chika.ink.opacity(0.97)],
                                   startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom))
        // Keep the scrubber in sync with programmatic page changes (taps/flicks) while not scrubbing.
        .onChange(of: page) { if !scrubbing { scrub = Double($0) } }
    }

    // Tap zones, matching Android: left third steps back, right third steps forward (panels are
    // pre-ordered in reading direction, so this is RTL-agnostic), middle third toggles chrome. The
    // double-tap (recenter) is disambiguated natively by the UIKit tap recognizers, so no defer.
    private func tapZone(x: CGFloat, width: CGFloat, in loader: PageLoader) {
        if x < width / 3 { advance(by: -1, in: loader) }
        else if x > width * 2 / 3 { advance(by: 1, in: loader) }
        else { withAnimation { showChrome.toggle() } }
    }

    // Whether the current slot frames the whole page (intro or outro) — a flick only turns pages here.
    private var isFullPage: Bool { step < 0 || step >= regions.count }

    // End of a one-finger drag: a fast horizontal flick from the whole-page view (intro or outro,
    // matching Android's isFullPageView) turns the page; otherwise the floated position is committed.
    private func endPan(velocity: CGSize, maxTouches: Int, in loader: PageLoader) {
        let isFlick = maxTouches == 1 && isFullPage && zoom <= 1.01
            && abs(velocity.width) > Self.flickVelocityPxS
            && abs(velocity.width) > abs(velocity.height) * Self.swipeHorizontalBias
        if isFlick {
            // swipe-left advances in LTR (and is mirrored under RTL); loadPage resets pan.
            turnPage(next: (velocity.width < 0) != rightToLeft, in: loader)
        } else {
            steadyPan = pan   // commit the floated / zoomed-pan position
        }
    }

    // Clamps free-pan so a floated/zoomed page can't be lost off-screen: horizontal "cover" (never
    // exposes side background), vertical "float" keeping ≥15% on screen — Android's clampPan ported
    // onto the same computePageDraw transform (scale about centre, then translate by pan).
    private func clampPan(_ raw: CGSize, viewSize: CGSize) -> CGSize {
        guard let image = image else { return raw }
        let cw = viewSize.width, ch = viewSize.height
        let draw = CameraTransformKt.computePageDraw(
            camera: camera,
            bitmapW: Int32(image.cgImage?.width ?? 1),
            bitmapH: Int32(image.cgImage?.height ?? 1),
            containerW: Float(cw), containerH: Float(ch), fill: 0.98)
        let scaledW = CGFloat(draw.scaledWidth) * zoom
        let scaledH = CGFloat(draw.scaledHeight) * zoom
        let baseLeft = cw / 2 + (CGFloat(draw.left) - cw / 2) * zoom
        let baseTop = ch / 2 + (CGFloat(draw.top) - ch / 2) * zoom
        let x: CGFloat = scaledW <= cw
            ? (cw - scaledW) / 2 - baseLeft
            : min(max(raw.width, cw - scaledW - baseLeft), -baseLeft)
        let keep = 0.15 * min(scaledH, ch)
        let y = min(max(raw.height, keep - scaledH - baseTop), ch - keep - baseTop)
        return CGSize(width: x, height: y)
    }

    private func advance(by delta: Int, in loader: PageLoader) {
        let next = step + delta
        if next > regions.count {                       // past the whole-page outro → next page intro
            guard page + 1 < loader.pageCount else { return }
            page += 1; loadPage(loader, restoreStep: -1)
        } else if next < -1 {                            // before the whole-page intro → prev page outro
            guard page > 0 else { return }
            page -= 1; loadPage(loader, restoreStep: Self.outroSlot)
        } else {
            withAnimation(Self.cameraTween) {            // tween the camera like Android (360ms)
                step = next                              // -1 intro · 0…n-1 panels · n outro
                resetZoom()
            }
            persist()
        }
    }

    /// Jumps to the whole-page view (Android's "show whole page" / ZoomOutMap), resetting any zoom.
    private func showWholePage() {
        withAnimation(Self.cameraTween) {
            step = -1
            resetZoom()
        }
        persist()
    }
}

/// Frames the page exactly like the shared computePageDraw (contain-fit the camera, fill 0.98),
/// then layers the user's pinch zoom / pan about the container centre — all as ONE animatable
/// transform. Because the camera rect itself is the animatable data, SwiftUI tweening it between
/// panels reproduces Android's `Animatable(camera, PanelConverter)` motion: the framing math runs
/// on every interpolated camera, not on interpolated screen rects.
private struct CameraFraming: GeometryEffect {
    var camL: CGFloat, camT: CGFloat, camR: CGFloat, camB: CGFloat
    var zoom: CGFloat
    var panX: CGFloat, panY: CGFloat
    var container: CGSize

    var animatableData: AnimatablePair<
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>,
        AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>
    > {
        get {
            AnimatablePair(
                AnimatablePair(AnimatablePair(camL, camT), AnimatablePair(camR, camB)),
                AnimatablePair(zoom, AnimatablePair(panX, panY)))
        }
        set {
            camL = newValue.first.first.first
            camT = newValue.first.first.second
            camR = newValue.first.second.first
            camB = newValue.first.second.second
            zoom = newValue.second.first
            panX = newValue.second.second.first
            panY = newValue.second.second.second
        }
    }

    // [size] is the Image's laid-out size: the page bitmap's pixel dimensions.
    func effectValue(size: CGSize) -> ProjectionTransform {
        let draw = CameraTransformKt.computePageDraw(
            camera: Panel(left: Float(camL), top: Float(camT), right: Float(camR), bottom: Float(camB)),
            bitmapW: Int32(max(size.width, 1)),
            bitmapH: Int32(max(size.height, 1)),
            containerW: Float(container.width),
            containerH: Float(container.height),
            fill: 0.98
        )
        let s = CGFloat(draw.scaledWidth) / max(size.width, 1)
        let cx = container.width / 2, cy = container.height / 2
        let left = cx + (CGFloat(draw.left) - cx) * zoom + panX
        let top = cy + (CGFloat(draw.top) - cy) * zoom + panY
        return ProjectionTransform(
            CGAffineTransform(translationX: left, y: top).scaledBy(x: s * zoom, y: s * zoom))
    }
}

/// Reading-direction control showing its current state (LTR/RTL) — a translucent cream pill with a
/// swap icon, matching Android's DirectionChip.
struct DirectionChip: View {
    let rightToLeft: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(Chika.cream)
                Text(rightToLeft ? "RTL" : "LTR")
                    .font(.archivo(11, weight: 700)).tracking(1).foregroundColor(Chika.cream)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Chika.cream.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
