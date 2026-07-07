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

    // Gesture tuning ported verbatim from Android's ReaderScreen so the reader "zones" behave
    // identically: a tap is deferred this long so a second tap reads as a double-tap; a page turn
    // needs a genuine horizontal *flick* (velocity, not distance), biased against vertical drags.
    private static let doubleTapWindow = 0.22          // Android DOUBLE_TAP_WINDOW_MS = 220ms
    private static let flickVelocityPxS: CGFloat = 700  // Android FLICK_VELOCITY_PX_S
    private static let swipeHorizontalBias: CGFloat = 1.2 // Android SWIPE_HORIZONTAL_BIAS
    private static let tapSlop: CGFloat = 10            // movement under this counts as a tap, not a drag
    // Sentinel restoreStep meaning "land on this page's whole-page outro" (used by backward turns);
    // resolved to regions.count once the page's regions are known.
    private static let outroSlot = Int.max

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
    // Pending deferred single tap (cancelled by a second tap → double-tap recenter), and the last
    // drag sample used to derive instantaneous flick velocity (DragGesture.velocity is iOS 17+).
    @State private var pendingTap: DispatchWorkItem?
    @State private var lastDragSample: (time: Date, tx: CGFloat, ty: CGFloat)?
    @State private var dragVelocity: CGSize = .zero

    private var title: String { comicURL.deletingPathExtension().lastPathComponent.uppercased() }
    // Slot model matching Android: step -1 = whole-page intro, 0…n-1 = panels, n = whole-page outro.
    // The intro and outro both frame the whole page, so page turns always land zoomed-out.
    private var camera: Panel {
        (step >= 0 && step < regions.count) ? regions[step] : Panel.companion.FULL_PAGE
    }
    // Whether the current slot is a framed panel (vs. the whole-page intro/outro).
    private var onPanel: Bool { step >= 0 && step < regions.count }

    var body: some View {
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
                readerBody(loader)
            }
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

        loadToken &+= 1
        let token = loadToken
        let target = page
        Self.ioQueue.async {
            let img = loader.loadPage(target) // downsampled + LRU-cached
            DispatchQueue.main.async {
                guard token == self.loadToken else { return } // a newer load superseded this one
                self.image = img
                if let cached = self.panelCache[target] {
                    self.regions = cached
                    // Keep intro (-1) / outro (count) as whole-page; clamp only strays past the outro.
                    if self.step > cached.count { self.step = cached.count }
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
                self.regions = found
                if self.step > found.count { self.step = found.count } // keep intro/outro/panel in range
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
    private func readerBody(_ loader: PageLoader) -> some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    let draw = CameraTransformKt.computePageDraw(
                        camera: camera,
                        bitmapW: Int32(image.cgImage?.width ?? 1),
                        bitmapH: Int32(image.cgImage?.height ?? 1),
                        containerW: Float(geo.size.width),
                        containerH: Float(geo.size.height),
                        // Fixed 0.98 contain-fill, matching Android (no user fill cycling).
                        fill: 0.98
                    )
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: CGFloat(draw.scaledWidth), height: CGFloat(draw.scaledHeight))
                        .offset(x: CGFloat(draw.left), y: CGFloat(draw.top))
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .scaleEffect(zoom)
                        .offset(pan)
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: page)
                } else {
                    ProgressView().tint(Chika.ochre)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay { if showChrome { Reticle(color: Chika.cream, inset: 6) } }
            .contentShape(Rectangle())
            // Unified pointer handling ported from Android's ReaderScreen so the "zones" match: a
            // single tap is deferred briefly so a second tap reads as a double-tap (recenter); pinch
            // zooms; a one-finger drag pans when zoomed, or a fast horizontal *flick* (velocity, not
            // distance) turns the whole page when viewing the full page — a slow drag just floats the
            // comic and stays put. The minimumDistance:0 drag captures taps too, so tap + double-tap
            // no longer fight each other the way the old SpatialTapGesture + count-2 tap did.
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in zoom = min(max(steadyZoom * value, 1), 5) }
                        .onEnded { _ in
                            if zoom <= 1.01 { resetZoom() } else { steadyZoom = zoom }
                        },
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            trackVelocity(value)
                            guard zoom > 1.01 else { return }
                            pan = CGSize(width: steadyPan.width + value.translation.width,
                                         height: steadyPan.height + value.translation.height)
                        }
                        .onEnded { value in
                            defer { lastDragSample = nil }
                            let t = value.translation
                            let moved = (t.width * t.width + t.height * t.height) > Self.tapSlop * Self.tapSlop
                            if zoom > 1.01 {
                                if moved { steadyPan = pan }
                                else { handleTap(value.location.x, width: geo.size.width, in: loader) }
                                return
                            }
                            guard moved else {
                                handleTap(value.location.x, width: geo.size.width, in: loader)
                                return
                            }
                            // A flick turns the page only from the full-page view (Android's isFullPage
                            // gate); on a framed panel you step with taps. Velocity separates a
                            // deliberate flick from a slow reposition.
                            guard step == -1 else { return }
                            let vx = dragVelocity.width, vy = dragVelocity.height
                            guard abs(vx) > Self.flickVelocityPxS,
                                  abs(vx) > abs(vy) * Self.swipeHorizontalBias else { return }
                            // swipe-left advances in LTR (and is mirrored under RTL)
                            turnPage(next: (vx < 0) != rightToLeft, in: loader)
                        }
                )
            )
        }
        .overlay(alignment: .top) { if showChrome { topBar } }
        .overlay(alignment: .bottom) { if showChrome { bottomBar } }
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
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Chika.cream)
                    .frame(width: 34, height: 34)
                    .background(Chika.inkSoft)
                    .clipShape(RoundedCornerShape(cornerRadius: 3))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.anton(15)).foregroundColor(Chika.cream).lineLimit(1)
                KickerText(pageStatus, size: 8)
            }
            Spacer()
            // Show whole page (Android's ZoomOutMap): jump back to the whole-page view from a panel.
            Button { withAnimation(.spring(response: 0.4)) { showWholePage() } } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(onPanel ? Chika.cream : Chika.creamMuted)
                    .frame(width: 34, height: 34)
                    .background(Chika.inkSoft)
                    .clipShape(RoundedCornerShape(cornerRadius: 3))
            }
            .disabled(!onPanel)
            Button(rightToLeft ? "RTL" : "LTR") {
                rightToLeft.toggle()
                panelCache.removeAll() // panels are ordered per-direction; re-detect under the new one
                persist(); redetect()
            }
                .font(.archivo(12)).foregroundColor(Chika.ink)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Chika.ochre)
                .clipShape(RoundedCornerShape(cornerRadius: 3))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Chika.ink.opacity(0.7))
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                KickerText("Swipe to turn", size: 8)
                Slider(
                    value: Binding(
                        get: { Double(page) },
                        set: { page = Int($0.rounded()); if case .ready(let a) = state { loadPage(a) } }
                    ),
                    in: 0...Double(max(pageCount - 1, 1)), step: 1
                )
                .tint(Chika.ochre)
                .frame(width: 180)
            }
            Spacer()
            PageCoin(page: page + 1, total: pageCount)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    /// Steps through panels, rolling over to the next/previous page at the ends.
    // Tap-zone + double-tap disambiguation, matching Android's deferred tap. Left third steps back,
    // right third steps forward (panels are pre-ordered in reading direction, so this is RTL-agnostic
    // exactly like Android), middle third toggles chrome. A second tap inside the window cancels the
    // pending step and recenters the view instead of navigating.
    private func handleTap(_ x: CGFloat, width: CGFloat, in loader: PageLoader) {
        if let pending = pendingTap {
            pending.cancel()
            pendingTap = nil
            withAnimation(.spring(response: 0.35)) { resetZoom() }
            return
        }
        let work = DispatchWorkItem {
            self.pendingTap = nil
            if x < width / 3 { self.advance(by: -1, in: loader) }
            else if x > width * 2 / 3 { self.advance(by: 1, in: loader) }
            else { withAnimation { self.showChrome.toggle() } }
        }
        pendingTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: work)
    }

    // Instantaneous drag velocity (px/s) from successive samples. DragGesture.velocity is iOS 17+ and
    // the app targets iOS 16, so we derive it from the per-event value.time deltas.
    private func trackVelocity(_ value: DragGesture.Value) {
        if let last = lastDragSample {
            let dt = CGFloat(value.time.timeIntervalSince(last.time))
            if dt > 0 {
                dragVelocity = CGSize(width: (value.translation.width - last.tx) / dt,
                                      height: (value.translation.height - last.ty) / dt)
            }
        }
        lastDragSample = (value.time, value.translation.width, value.translation.height)
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
            step = next                                  // -1 intro · 0…n-1 panels · n outro
            resetZoom()
            persist()
        }
    }

    /// Jumps to the whole-page view (Android's "show whole page" / ZoomOutMap), resetting any zoom.
    private func showWholePage() {
        step = -1
        resetZoom()
        persist()
    }
}
