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
    // overlay all detected panels on the whole page; CHIKA_DEBUG_BOXES forces it on at launch (QA).
    @State private var debugBoxes = ProcessInfo.processInfo.environment["CHIKA_DEBUG_BOXES"] != nil
    // Manual zoom/pan layered on top of the panel-framing camera (pinch to zoom, drag to pan).
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var steadyPan: CGSize = .zero
    // How tightly a panel fills the screen; user-cyclable for taste (display-only, no detect impact).
    @State private var fill: Float = ReadingPrefs.zoomFill

    private var title: String { comicURL.deletingPathExtension().lastPathComponent.uppercased() }
    private var camera: Panel {
        if debugBoxes { return Panel.companion.FULL_PAGE } // show the full page to overlay all boxes
        return (step >= 0 && step < regions.count) ? regions[step] : Panel.companion.FULL_PAGE
    }

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
        step = restoreStep
        regions = panelCache[page] ?? [Panel.companion.FULL_PAGE]
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
                    if self.step >= cached.count { self.step = cached.count - 1 }
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
                if self.step >= found.count { self.step = found.count - 1 } // keep a restored panel in range
                self.detecting = false
                // QA hook: auto-split the current region once, to demonstrate the manual split.
                if ProcessInfo.processInfo.environment["CHIKA_DEBUG_SPLIT"] != nil, self.step >= 0 {
                    self.splitCurrentRegion()
                }
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
                        // Default 0.98 matches Android; user can cycle this in the reader for taste.
                        fill: fill
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
            .overlay {
                // Debug: draw every planned panel box (in reading order) over the whole page, so a
                // screenshot can be compared to Android to confirm detection parity.
                if debugBoxes, let image {
                    Canvas { ctx, sz in
                        let d = CameraTransformKt.computePageDraw(
                            camera: Panel.companion.FULL_PAGE,
                            bitmapW: Int32(image.cgImage?.width ?? 1),
                            bitmapH: Int32(image.cgImage?.height ?? 1),
                            containerW: Float(sz.width), containerH: Float(sz.height), fill: 0.98)
                        let ox = CGFloat(d.left), oy = CGFloat(d.top)
                        let sw = CGFloat(d.scaledWidth), sh = CGFloat(d.scaledHeight)
                        for (i, r) in regions.enumerated() {
                            let rect = CGRect(x: ox + CGFloat(r.left) * sw, y: oy + CGFloat(r.top) * sh,
                                              width: CGFloat(r.width) * sw, height: CGFloat(r.height) * sh)
                            ctx.stroke(Path(rect), with: .color(.red), lineWidth: 2)
                            ctx.draw(Text("\(i + 1)").font(.system(size: 15, weight: .black)).foregroundColor(.yellow),
                                     at: CGPoint(x: rect.minX + 12, y: rect.minY + 12))
                        }
                        // Diagnostic readout: overlap score + panel count (for tuning the reliability gate).
                        let ovl = PanelReliability.shared.overlapScore(panels: regions)
                        let reliable = PanelReliability.shared.isReliable(panels: regions)
                        ctx.draw(Text(String(format: "ovl=%.3f n=%d %@", ovl, regions.count, reliable ? "OK" : "FALLBACK"))
                            .font(.system(size: 16, weight: .black)).foregroundColor(.green),
                                 at: CGPoint(x: sz.width / 2, y: 24))
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            // Pinch to zoom; drag to pan when zoomed, or swipe to turn the page when not.
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in zoom = min(max(steadyZoom * value, 1), 5) }
                        .onEnded { _ in
                            if zoom <= 1.01 { resetZoom() } else { steadyZoom = zoom }
                        },
                    DragGesture(minimumDistance: 14)
                        .onChanged { value in
                            guard zoom > 1.01 else { return }
                            pan = CGSize(width: steadyPan.width + value.translation.width,
                                         height: steadyPan.height + value.translation.height)
                        }
                        .onEnded { value in
                            if zoom > 1.01 { steadyPan = pan; return }
                            let dx = value.translation.width
                            guard abs(dx) > 50, abs(dx) > abs(value.translation.height) else { return }
                            // swipe-left advances in LTR (and is mirrored under RTL)
                            turnPage(next: (dx < 0) != rightToLeft, in: loader)
                        }
                )
            )
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard zoom <= 1.01 else { withAnimation { showChrome.toggle() }; return }
                    let x = value.location.x
                    if x > geo.size.width * 0.66 { advance(by: 1, in: loader) }
                    else if x < geo.size.width * 0.33 { advance(by: -1, in: loader) }
                    else { withAnimation { showChrome.toggle() } }
                }
            )
            .highPriorityGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.spring(response: 0.35)) {
                        if zoom > 1.01 { resetZoom() } else { zoom = 2.5; steadyZoom = 2.5 }
                    }
                }
            )
        }
        .overlay(alignment: .top) { if showChrome { topBar } }
        .overlay(alignment: .bottom) { if showChrome { bottomBar } }
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
                HStack(spacing: 6) {
                    // "Whole page" signals the detection-confidence fallback (auto-pan off here).
                    KickerText(detecting ? "Detecting…" : (regions.count <= 1 ? "Whole page" : "Reading"), size: 8)
                }
            }
            Spacer()
            // Manual split: halve the current region when the detector merged multiple panels.
            Button { withAnimation(.spring(response: 0.4)) { splitCurrentRegion() } } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(step >= 0 ? Chika.cream : Chika.creamMuted)
                    .frame(width: 34, height: 34)
                    .background(Chika.inkSoft)
                    .clipShape(RoundedCornerShape(cornerRadius: 3))
            }
            .disabled(step < 0)
            // Developer panel-box overlay toggle (kept visible for now at user request).
            Button { debugBoxes.toggle() } label: {
                Image(systemName: debugBoxes ? "square.dashed.inset.filled" : "square.dashed")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(debugBoxes ? Chika.ochre : Chika.cream)
                    .frame(width: 34, height: 34)
                    .background(Chika.inkSoft)
                    .clipShape(RoundedCornerShape(cornerRadius: 3))
            }
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
                KickerText(step < 0 ? "Tap right to step" : "Tap to step · swipe to turn", size: 8)
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
            // Cycle how tightly panels fill the screen (more padding ↔ edge-to-edge).
            Button { cycleFill() } label: {
                VStack(spacing: 1) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                    Text("\(Int((fill * 100).rounded()))").font(.archivo(9))
                }
                .foregroundColor(Chika.cream)
                .frame(width: 38, height: 38)
                .background(Chika.inkSoft)
                .clipShape(RoundedCornerShape(cornerRadius: 3))
            }
            .padding(.trailing, 8)
            PageCoin(page: page + 1, total: pageCount)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    /// Steps through panels, rolling over to the next/previous page at the ends.
    private func advance(by delta: Int, in loader: PageLoader) {
        let next = step + delta
        if next >= regions.count {
            guard page + 1 < loader.pageCount else { return }
            page += 1; loadPage(loader)
        } else if next < -1 {
            guard page > 0 else { return }
            page -= 1; loadPage(loader)
        } else {
            step = next
            resetZoom()
            persist()
        }
    }

    /// Splits the current framed region in half along its longer screen axis (RTL-aware) — a manual
    /// workaround for when the detector merges several real panels into one box. The override is
    /// cached per page so it survives navigation within this comic (session-only, not persisted).
    private func splitCurrentRegion() {
        guard step >= 0, step < regions.count, let cg = image?.cgImage else { return }
        let r = regions[step]
        let realW = Double(r.width) * Double(cg.width)
        let realH = Double(r.height) * Double(cg.height)
        let halves: [Panel]
        if realW >= realH {
            let midX = (r.left + r.right) / 2
            let left = Panel(left: r.left, top: r.top, right: midX, bottom: r.bottom)
            let right = Panel(left: midX, top: r.top, right: r.right, bottom: r.bottom)
            halves = rightToLeft ? [right, left] : [left, right]   // reading-first half stays at `step`
        } else {
            let midY = (r.top + r.bottom) / 2
            halves = [Panel(left: r.left, top: r.top, right: r.right, bottom: midY),
                      Panel(left: r.left, top: midY, right: r.right, bottom: r.bottom)]
        }
        var updated = regions
        updated.replaceSubrange(step...step, with: halves)
        regions = updated
        panelCache[page] = updated   // keep the override when returning to this page
        resetZoom()
        persist()
    }

    /// Cycles how tightly panels fill the screen (more padding ↔ edge-to-edge), persisted globally.
    private func cycleFill() {
        let levels = ReadingPrefs.fillLevels
        let idx = levels.firstIndex(where: { abs($0 - fill) < 0.001 }) ?? levels.count - 1
        fill = levels[(idx + 1) % levels.count]
        ReadingPrefs.zoomFill = fill
    }
}
