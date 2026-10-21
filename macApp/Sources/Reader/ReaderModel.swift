import SwiftUI
import ChikaCore

/// One open comic: archive → pages, the page/slot state machine (ChikaCore.ReaderSlots), panel
/// detection and saved progress. Shared by the reader window and the peek window, so stepping in
/// either moves both. Panels come from the on-device Core ML detector via the shared decoder +
/// planner; the views frame the camera with the shared computePageDraw.
@MainActor
final class ReaderModel: ObservableObject {
    enum LoadState: Equatable { case loading, failed(String), ready }

    private nonisolated static let detector = CoreMLPanelDetector()
    private nonisolated static let ioQueue = DispatchQueue(label: "chika.reader.io", qos: .userInitiated)
    private nonisolated static let detectQueue = DispatchQueue(label: "chika.reader.detect", qos: .userInitiated)
    // Android's camera motion: tween(360, FastOutSlowInEasing) between framed views.
    // FastOutSlowIn == cubic-bezier(0.4, 0, 0.2, 1).
    static let cameraTween = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.36)

    let comicURL: URL
    @Published private(set) var state: LoadState = .loading
    @Published private(set) var slots = ReaderSlots() {
        // Only real moves: each save makes the library window refresh.
        didSet { if slots.page != oldValue.page || slots.step != oldValue.step { persist() } }
    }
    @Published private(set) var image: CGImage?
    @Published private(set) var detecting = false
    @Published private(set) var pageAlpha: Double = 1   // per-page fade-in (Android's 280ms)
    @Published var rightToLeft: Bool
    private(set) var pageCount = 1
    var title: String { comicURL.deletingPathExtension().lastPathComponent }

    private var loader: PageLoader?
    private var loadToken = 0
    // Detected panels cached per page (in the current reading direction) so back/forward and
    // prefetched pages don't re-run the detector. Cleared when the direction changes.
    private var panelCache: [Int: [Panel]] = [:]

    init(comicURL: URL, settings: ChikaSettings) {
        self.comicURL = comicURL
        // Reading direction: this comic's saved choice, or the global default if never set.
        rightToLeft = ReadingProgress.readingDirection(comicURL, default: settings.defaultRightToLeft)
        // Views create the model mid-render; loading writes progress, which the library observes, so
        // run it on the next turn (as iOS's `.task { load() }` did).
        DispatchQueue.main.async { self.load() }
    }

    private func load() {
        do {
            let loader = PageLoader(archive: try CbzArchive(url: comicURL))
            guard loader.pageCount > 0 else { state = .failed("No image pages found in this archive"); return }
            self.loader = loader
            pageCount = loader.pageCount
            // Resume where we left off (page and panel), clamped to the current page count. The step
            // stays as saved; ReaderSlots clamps it once this page's regions are known.
            let saved = ReadingProgress.get(comicURL)
            slots = ReaderSlots(page: min(max(saved?.page ?? 0, 0), pageCount - 1), step: saved?.step ?? -1)
            state = .ready
            ReadingProgress.markOpened(comicURL)   // bump recency so it sorts to the top of the library
            loadPage()
        } catch {
            state = .failed("Could not open archive: \(error.localizedDescription)")
        }
    }

    /// Loads the current page's image OFF the main thread. Reading + decoding a multi-MB page on the
    /// main thread (e.g. on every slider tick while scrubbing) blocks the UI. A serial queue avoids
    /// piling up concurrent ZIP reads, and a token ensures only the latest page renders when
    /// scrubbing fast.
    private func loadPage() {
        guard let loader else { return }
        // Known panels apply at once (resolving a backward turn's outro); unknown ones stay nil and
        // block stepping until detection lands.
        if let cached = panelCache[slots.page] { slots.setRegions(cached) }
        detecting = false
        pageAlpha = 0.35   // fades up to 1 once the page renders

        loadToken &+= 1
        let token = loadToken
        let target = slots.page
        Self.ioQueue.async {
            let img = loader.loadPage(target) // downsampled + LRU-cached
            DispatchQueue.main.async {
                guard token == self.loadToken else { return } // a newer load superseded this one
                self.image = img
                withAnimation(.easeOut(duration: 0.28)) { self.pageAlpha = 1 }
                if self.slots.regions == nil {
                    // An undecodable page reads as one whole-page region so the reader can step past it.
                    if img == nil { self.slots.setRegions([.fullPage]) } else { self.redetect() }
                }
                self.prefetch(target + 1)
            }
        }
    }

    private func redetect() {
        guard let img = image else { return }
        let rtl = rightToLeft
        let forPage = slots.page
        detecting = true
        // Serial queue + page guard: scrubbing fast enqueues detections instead of running them
        // concurrently, and stale results for a page we've already left are only cached.
        Self.detectQueue.async {
            let found = Self.detector.zoomRegions(for: img, rightToLeft: rtl)
            DispatchQueue.main.async { self.landed(found, page: forPage, rtl: rtl) }
        }
    }

    /// Warms the next page in the background — decode (LRU-cached) + detect (panel-cached) — so
    /// stepping onto it is instant instead of stalling on a multi-MB decode + inference.
    private func prefetch(_ index: Int) {
        guard let loader, index < pageCount, panelCache[index] == nil else { return }
        let rtl = rightToLeft
        Self.detectQueue.async {
            guard let img = loader.loadPage(index) else { return }
            let found = Self.detector.zoomRegions(for: img, rightToLeft: rtl)
            DispatchQueue.main.async { self.landed(found, page: index, rtl: rtl) }
        }
    }

    /// A detection finished: cache it, and if we're still on that page, glide into its panels.
    private func landed(_ found: [Panel], page: Int, rtl: Bool) {
        guard rtl == rightToLeft else { return } // direction changed; the cache would be stale
        panelCache[page] = found
        guard page == slots.page else { return }
        withAnimation(Self.cameraTween) { slots.setRegions(found) }
        detecting = false
    }

    private func persist() {
        ReadingProgress.set(comicURL, page: slots.page, step: slots.step, total: pageCount, rtl: rightToLeft)
    }

    /// Steps through slots (intro → panels → outro), crossing into the neighbouring page at either end.
    func advance(by delta: Int) {
        let move = withAnimation(Self.cameraTween) { slots.advance(by: delta, pageCount: pageCount) }
        if move == .nextPage || move == .previousPage { loadPage() }
    }

    /// Turns a whole page, landing on its whole-page intro. [next] is reading-forward.
    func turnPage(next: Bool) { goToPage(slots.page + (next ? 1 : -1)) }

    func goToPage(_ index: Int) {
        guard index >= 0, index < pageCount else { return }
        slots = ReaderSlots(page: index)
        loadPage()
    }

    /// Jumps to the whole-page view (Android's "show whole page" / ZoomOutMap).
    func showWholePage() {
        withAnimation(Self.cameraTween) { slots.showWholePage() }
    }

    func toggleDirection() {
        rightToLeft.toggle()
        panelCache.removeAll() // panels are ordered per-direction; re-detect under the new one
        persist(); redetect()
    }
}

/// App-wide registry so both windows for one comic observe the same model. Windows attach on
/// appear and detach on disappear; the model (and its page cache) is dropped once no window shows it.
@MainActor
final class ReaderModels: ObservableObject {
    // Not @Published: views create models while rendering, and nothing observes the dictionary.
    private var models: [URL: ReaderModel] = [:]
    private var attached: [URL: Int] = [:]

    func model(for url: URL, settings: ChikaSettings) -> ReaderModel {
        if let model = models[url] { return model }
        let model = ReaderModel(comicURL: url, settings: settings)
        models[url] = model
        return model
    }

    func attach(_ url: URL) { attached[url, default: 0] += 1 }

    func detach(_ url: URL) {
        attached[url, default: 1] -= 1
        if attached[url, default: 0] <= 0 { release(url) }
    }

    func release(_ url: URL) { attached[url] = nil; models[url] = nil }
}
