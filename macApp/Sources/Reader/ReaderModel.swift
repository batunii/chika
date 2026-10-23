import SwiftUI
import AppKit
import ChikaCore

/// How a comic is read: panel by panel behind the camera, two facing pages, or one vertical strip.
enum ReadingMode: String, CaseIterable {
    case panels, spread, scroll
    var title: String { ["panels": "Panels", "spread": "Two pages", "scroll": "Scroll"][rawValue]! }
}

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
    @Published private(set) var facing: CGImage?   // spread mode: the spread's second page
    private var imagePages: [Int] = []   // the pages `image` and `facing` hold; behind slots while one loads
    @Published private(set) var mode: ReadingMode
    @Published private(set) var detecting = false
    @Published private(set) var pageAlpha: Double = 1   // per-page fade-in (Android's 280ms)
    @Published var rightToLeft: Bool
    @Published private(set) var bookmarks: [Bookmark]
    /// The reader's panel editor is open: peek auto-advance holds so the reading position stays put.
    @Published var editingPanels = false
    private(set) var pageCount = 1
    var title: String { comicURL.deletingPathExtension().lastPathComponent }

    private var loader: PageLoader?
    private var loadToken = 0
    // Detected panels cached per page (in the current reading direction) so back/forward and
    // prefetched pages don't re-run the detector. Cleared when the direction changes. Behind it, every
    // detection is stored in the progress database (both directions), so a reopened comic skips the detector.
    private var panelCache: [Int: [Panel]] = [:]
    // Panels drawn by hand in the panel editor, per page, read from the database as each page loads.
    // They win over detection and keep their stored order in either reading direction.
    @Published private var overrides: [Int: [Panel]] = [:]
    // Pages found to be wider than tall (scanned double pages): they stand alone in a spread.
    private var widePages: Set<Int> = []

    /// Pages on screen, in reading order: the spread in spread mode, else the current page.
    var visiblePages: [Int] {
        mode == .spread ? Spreads.spread(containing: slots.page, pageCount: pageCount, wide: widePages) : [slots.page]
    }
    var onLastPage: Bool { visiblePages.contains(pageCount - 1) }
    /// The bookmark for where the reader is: the panel in panels mode, else the (first visible) page.
    var here: Bookmark { Bookmark(page: visiblePages[0], step: mode == .panels && slots.onPanel ? slots.step : -1) }
    /// The bookmarks on screen: the one at `here` in panels mode, any on a visible page in Two pages and Scroll.
    var marksHere: [Bookmark] { bookmarks.filter { mode == .panels ? $0 == here : visiblePages.contains($0.page) } }
    /// The current page's panels were drawn by hand in the panel editor.
    var pageEdited: Bool { mode == .panels && overrides[slots.page] != nil }
    /// The panel editor (⌘E) needs Panels mode with this page and its panels on screen.
    var canEditPanels: Bool { mode == .panels && image != nil && imagePages == visiblePages && slots.regions != nil && !detecting }
    /// The comic is opening, or the page on screen still lacks its image or (panels mode) its panels:
    /// peek auto-advance holds its wait until this clears.
    // shortcut: Scroll skips the image check because the strip's scrolled(to:) never loads `image`; check it
    // too once scrolled(to:) decodes the page.
    var waitingForPage: Bool {
        switch state {
        case .loading: return true
        case .failed: return false
        case .ready: return (mode != .scroll && imagePages != visiblePages) || (mode == .panels && slots.regions == nil)
        }
    }

    init(comicURL: URL, settings: ChikaSettings) {
        self.comicURL = comicURL
        // Reading direction: this comic's saved choice, or the global default if never set.
        rightToLeft = ReadingProgress.readingDirection(comicURL, default: settings.defaultRightToLeft)
        mode = ReadingProgress.get(comicURL)?.mode.flatMap(ReadingMode.init(rawValue:)) ?? .panels
        bookmarks = ReadingProgress.bookmarks(comicURL)
        // Views create the model mid-render; loading writes progress, which the library observes, so
        // run it on the next turn (as iOS's `.task { load() }` did).
        DispatchQueue.main.async { self.load() }
    }

    private func load() {
        // Off the main thread: a CBR read in place converts on its first open.
        let url = comicURL
        Self.ioQueue.async {
            let opened = Result { try ComicOpener.open(url) }
            DispatchQueue.main.async { self.loaded(opened) }
        }
    }

    private func loaded(_ opened: Result<ComicPages, Error>) {
        do {
            let loader = PageLoader(archive: try opened.get())
            guard loader.pageCount > 0 else { state = .failed("No image pages found in this archive"); return }
            self.loader = loader
            pageCount = loader.pageCount
            // Resume where we left off (page and panel), clamped to the current page count. The step
            // stays as saved; ReaderSlots clamps it once this page's regions are known.
            let saved = ReadingProgress.get(comicURL)
            slots = ReaderSlots(page: min(max(saved?.page ?? 0, 0), pageCount - 1),
                                step: mode == .panels ? saved?.step ?? -1 : -1)
            state = .ready
            ReadingProgress.markOpened(comicURL)   // bump recency so it sorts to the top of the library
            loadPage()
            BookPredetector.shared.add(comicURL)   // the pages not stored yet, in the background
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
        // block stepping until detection lands. A bookmark's panel waits for its page's image, so the
        // camera never frames it on the page still on screen.
        if mode == .panels {
            overrides[slots.page] = ReadingProgress.panelOverride(comicURL, page: slots.page)
            if let known = knownRegions(slots.page),
               slots.step == -1 || slots.step == ReaderSlots.outroSentinel { slots.setRegions(known) }
        }
        detecting = false
        pageAlpha = 0.35   // fades up to 1 once the page renders

        loadToken &+= 1
        let token = loadToken
        let pages = visiblePages
        let target = pages[0]
        Self.ioQueue.async {
            let images = pages.map { loader.loadPage($0) } // downsampled + LRU-cached
            DispatchQueue.main.async {
                guard token == self.loadToken else { return } // a newer load superseded this one
                self.noteWide(zip(pages, images))
                // A page of this spread turned out to be a double page: pair again and reload.
                if self.visiblePages != pages { self.loadPage(); return }
                self.image = images[0]
                self.facing = images.count > 1 ? images[1] : nil
                self.imagePages = pages
                withAnimation(.easeOut(duration: 0.28)) { self.pageAlpha = 1 }
                guard self.mode == .panels else { self.prefetchSpread(after: pages.last!); return }
                let img = images[0]
                // Also when the regions came from a cache that a direction flip or a reset cleared during the load.
                if self.slots.regions == nil || self.knownRegions(target) == nil {
                    // A bookmark's known panels glide in now. An undecodable page reads as one
                    // whole-page region so the reader can step past it.
                    if let known = self.knownRegions(target) {
                        withAnimation(Self.cameraTween) { self.slots.setRegions(known) }
                    } else if img == nil { self.slots.setRegions([.fullPage]) } else { self.redetect() }
                }
                self.prefetch(target + 1)
            }
        }
    }

    /// A page's panels without running the detector: drawn by hand, cached, or stored by an earlier
    /// detection (the reader's or the background pre-detection's).
    private func knownRegions(_ page: Int) -> [Panel]? {
        if let known = overrides[page] ?? panelCache[page] { return known }
        panelCache[page] = ReadingProgress.detection(comicURL, page: page, rtl: rightToLeft)?.regions
        return panelCache[page]
    }

    private func redetect() {
        // While the page loads, `image` is the previous page; the load detects once it lands.
        guard imagePages == visiblePages, let img = image else { return }
        let forPage = slots.page
        // After a direction flip or a reset the stored detection usually has the page already.
        if let known = knownRegions(forPage) { landed(known, page: forPage); return }
        detecting = true
        // Serial queue + page guard: scrubbing fast enqueues detections instead of running them
        // concurrently, and stale results for a page we've already left are only cached.
        Self.detectQueue.async {
            let found = Self.detector.detect(img)
            DispatchQueue.main.async { self.detected(found, page: forPage) }
        }
    }

    /// Warms the next page in the background — decode (LRU-cached) + detect (panel-cached) — so
    /// stepping onto it is instant instead of stalling on a multi-MB decode + inference.
    private func prefetch(_ index: Int) {
        guard let loader, index < pageCount, panelCache[index] == nil else { return }
        let detect = knownRegions(index) == nil && ReadingProgress.panelOverride(comicURL, page: index) == nil
        Self.detectQueue.async {
            guard let img = loader.loadPage(index), detect else { return }   // a known or edited page only needs the decode
            let found = Self.detector.detect(img)
            DispatchQueue.main.async { self.detected(found, page: index) }
        }
    }

    private func noteWide<S: Sequence>(_ loaded: S) where S.Element == (Int, CGImage?) {
        for (page, image) in loaded where (image.map { $0.width > $0.height }) == true { widePages.insert(page) }
    }

    /// Spread mode's prefetch: decode the next spread (and learn whether its pages are wide).
    private func prefetchSpread(after page: Int) {
        guard mode == .spread, let loader, page + 1 < pageCount else { return }
        let next = Spreads.spread(containing: page + 1, pageCount: pageCount, wide: widePages)
        Self.ioQueue.async {
            let images = next.map { loader.loadPage($0) }
            DispatchQueue.main.async { self.noteWide(zip(next, images)) }
        }
    }

    /// The detector ran: store the result (both directions, so a flip needs no rerun) and land the
    /// current direction's regions. A failed run reads the page whole and stores nothing.
    private func detected(_ found: PageDetection?, page: Int) {
        if let found { ReadingProgress.setDetection(comicURL, page: page, found) }
        landed(found?.regions(rightToLeft: rightToLeft) ?? [.fullPage], page: page)
    }

    /// A detection finished: cache it, and if we're still on that page, glide into its panels.
    private func landed(_ found: [Panel], page: Int) {
        // No camera to move, or a page whose panels were drawn by hand.
        guard mode == .panels, overrides[page] == nil else { return }
        panelCache[page] = found
        // A page still loading picks the panels up from the cache, so a bookmark's panel is never framed on the previous page.
        guard page == slots.page, imagePages == visiblePages else { return }
        withAnimation(Self.cameraTween) { slots.setRegions(found) }
        detecting = false
    }

    private func persist() {
        // A spread saves its last page, so finishing the last spread counts as read to the end.
        ReadingProgress.set(comicURL, page: visiblePages.last ?? slots.page, step: slots.step, total: pageCount,
                            rtl: rightToLeft, mode: mode.rawValue)
    }

    /// Steps through slots (intro → panels → outro), crossing into the neighbouring page at either
    /// end. In spread mode a step is a whole spread; in scroll mode a page (the strip follows).
    /// Returns the move: .blocked is the end of the book, or (panels mode, regions nil) waiting for detection.
    @discardableResult
    func advance(by delta: Int) -> ReaderSlots.Move {
        switch mode {
        case .panels:
            let move = withAnimation(Self.cameraTween) { slots.advance(by: delta, pageCount: pageCount) }
            if move == .nextPage || move == .previousPage { loadPage() }
            return move
        case .spread:
            let spreads = Spreads.pairs(pageCount: pageCount, wide: widePages)
            let i = (spreads.firstIndex { $0.contains(slots.page) } ?? 0) + delta
            guard spreads.indices.contains(i) else { return .blocked }
            goToPage(spreads[i][0])
            return delta > 0 ? .nextPage : .previousPage
        case .scroll:
            guard (0..<pageCount).contains(slots.page + delta) else { return .blocked }
            goToPage(slots.page + delta)
            return delta > 0 ? .nextPage : .previousPage
        }
    }

    /// Turns a whole page (a whole spread in spread mode), landing on its whole-page intro.
    /// [next] is reading-forward.
    func turnPage(next: Bool) {
        if mode == .spread { advance(by: next ? 1 : -1) } else { goToPage(slots.page + (next ? 1 : -1)) }
    }

    /// Scroll mode's page image, limited on its short edge so a tall strip keeps its width.
    func scrollImage(_ index: Int) async -> CGImage? {
        guard let loader else { return nil }
        return await withCheckedContinuation { done in
            Self.ioQueue.async { done.resume(returning: loader.loadPage(index, fitWidth: true)) }
        }
    }

    /// Scroll mode: the page at the top of the strip is the reading position.
    // shortcut: doesn't reload `image`, so a peek window opened in scroll mode keeps the page it
    // started on; decode it here if peek and scroll get used together (it would slow fast flicks).
    func scrolled(to page: Int) {
        if page != slots.page { slots = ReaderSlots(page: page) }
    }

    /// What is being read, as one image (Copy and Export Panel): the camera's crop of the page in
    /// panels mode, the spread's pages side by side as on screen, the page at the top in scroll mode.
    /// Nil while the page is still loading, so a quick ⇧⌘E never saves the previous page.
    func readingImage() -> CGImage? {
        switch mode {
        case .panels, .spread:
            guard imagePages == visiblePages else { return nil }
            if mode == .panels { return cameraImage() }
            let pages = [image, facing].compactMap { $0 }
            return Self.sideBySide(rightToLeft ? pages.reversed() : pages)
        case .scroll:
            // shortcut: decodes on the main thread, a cache hit while the page is on screen (the strip
            // loaded it with the same key); move to ioQueue if a copy ever stalls.
            return loader?.loadPage(slots.page, fitWidth: true)
        }
    }

    /// The camera's crop of `image`: panels mode's reading image, and in Scroll what the peek shows.
    func cameraImage() -> CGImage? {
        guard let image else { return nil }
        let r = slots.camera.pixelRect(width: image.width, height: image.height)
        return image.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
    }

    /// Copy (⌘C, Edit > Copy): what the reader shows, or with [peek] what the peek window shows.
    func copyItems(peek: Bool = false) -> [NSItemProvider] {
        // Only Scroll's peek keeps its own page in `image`; elsewhere readingImage holds back while a page loads.
        (peek && mode == .scroll ? cameraImage() : readingImage()).map { [NSItemProvider(object: NSImage(cgImage: $0, size: .zero))] } ?? []
    }

    /// Pages joined left to right, each scaled to the tallest one's height.
    nonisolated static func sideBySide(_ pages: [CGImage]) -> CGImage? {
        guard let height = pages.map(\.height).max() else { return nil }
        let widths = pages.map { $0.width * height / $0.height }
        guard let context = CGContext(data: nil, width: widths.reduce(0, +), height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var x = 0
        for (page, width) in zip(pages, widths) {
            context.draw(page, in: CGRect(x: x, y: 0, width: width, height: height))
            x += width
        }
        return context.makeImage()
    }

    func setMode(_ newMode: ReadingMode) {
        guard newMode != mode else { return }
        mode = newMode
        facing = nil
        goToPage(slots.page)   // the whole page (or its spread), re-detected or re-paired
        persist()
    }

    /// Goes to a page; in panels mode a bookmark's [step] lands on its panel once the page's regions
    /// are known (ReaderSlots clamps it, as on resume).
    func goToPage(_ index: Int, step: Int = -1) {
        guard index >= 0, index < pageCount else { return }
        slots = ReaderSlots(page: index, step: mode == .panels ? step : -1)
        loadPage()
    }

    /// Removes the bookmarks on screen, or bookmarks `here` if there are none.
    func toggleBookmark() {
        guard state == .ready else { return }   // before the comic opens, "here" is a placeholder page 0
        let marks = marksHere
        for mark in marks.isEmpty ? [here] : marks { ReadingProgress.toggleBookmark(comicURL, page: mark.page, step: mark.step) }
        bookmarks = ReadingProgress.bookmarks(comicURL)
    }

    /// Jumps to the whole-page view (Android's "show whole page" / ZoomOutMap).
    func showWholePage() {
        withAnimation(Self.cameraTween) { slots.showWholePage() }
    }

    func toggleDirection() {
        rightToLeft.toggle()
        panelCache.removeAll() // panels are ordered per-direction; re-detect under the new one
        persist()
        if mode == .panels && overrides[slots.page] == nil { redetect() }
    }

    /// Saves the panel editor's [panels] (reading order) as [page]'s panels in place of detection;
    /// [drawn] = every box was drawn by hand, so the training export may use the page.
    /// False if the database write failed: nothing changes, so the editor can keep the edits.
    func savePanels(_ panels: [Panel], page: Int, drawn: Bool = false) -> Bool {
        let panels = panels.isEmpty ? [.fullPage] : panels   // as detection does when it finds nothing
        guard ReadingProgress.setPanelOverride(comicURL, page: page, panels: panels, drawn: drawn) else { return false }
        overrides[page] = panels
        if page == slots.page {
            detecting = false   // a detection still running for this page is dropped when it lands
            withAnimation(Self.cameraTween) { slots.setRegions(panels) }
        }
        return true
    }

    /// Drops [page]'s hand-drawn panels and detects them again.
    func resetPanels(page: Int) {
        guard overrides.removeValue(forKey: page) != nil else { return }   // not edited: detection already shows
        ReadingProgress.deletePanelOverride(comicURL, page: page)
        if page == slots.page { redetect() }
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
