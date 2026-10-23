import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Translation
import ChikaCore

/// Panel-by-panel comic reader with Chika chrome: a branded header (back + title + status), reticle
/// brackets framing the page, the starburst page coin, and an "arrow keys to read" hint — matching
/// the Android reader. Clicking the right side steps page → panel 1 → … → next page; the left side
/// steps back. The model lives in `ReaderModels`, so the peek window shares it.
struct ReaderView: View {
    let comicURL: URL
    @EnvironmentObject private var readers: ReaderModels
    @EnvironmentObject private var settings: ChikaSettings

    var body: some View {
        ReaderContent(model: readers.model(for: comicURL, settings: settings))
            .onAppear { readers.attach(comicURL); ReadingProgress.markOpened(comicURL) }
            .onDisappear { readers.detach(comicURL) }
    }
}

private struct ReaderContent: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var settings: ChikaSettings
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    // Manual zoom/pan layered on top of the panel-framing camera (pinch to zoom, drag to pan).
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var steadyPan: CGSize = .zero
    // Page scrubber state (commit on release, not per-tick).
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    @FocusState private var focused: Bool
    // Scroll mode's position, moved by keys and page jumps; offset and viewport feed screen steps.
    @State private var scroll = ScrollPosition(idType: Int.self)
    @State private var scrollY: CGFloat = 0
    @State private var viewport: CGFloat = 0
    // The panel editor replaces the page and both bars (so their Esc and Return shortcuts are gone).
    @State private var editing = false
    @StateObject private var translator = BalloonTranslator()
    @StateObject private var speaker = BalloonSpeaker()
    @State private var voiceOver = NSWorkspace.shared.isVoiceOverEnabled

    private var isReady: Bool { model.state == .ready }
    private var marked: Bool { !model.marksHere.isEmpty }

    var body: some View {
        ZStack {
            settings.ground.ignoresSafeArea()
            switch model.state {
            case .loading:
                ProgressView().tint(Chika.ochre)
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(Chika.ochre)
                    Text(message).font(.archivo(14)).foregroundColor(Chika.cream)
                        .multilineTextAlignment(.center)
                }
                .padding()
            case .ready:
                if editing {
                    PanelEditor(model: model) { editing = false }
                } else {
                    GeometryReader { screen in
                        readerBody(size: screen.size)
                    }
                }
            }
        }
        .overlay(alignment: .top) { if isReady && !editing { topBar } }
        .overlay(alignment: .bottom) { if isReady && !editing && model.pageCount > 1 { bottomBar } }
        .overlay(alignment: .topLeading) {
            if !isReady {
                Button { dismiss() } label: {
                    Label("Library", systemImage: "arrow.left")
                        .font(.archivo(14)).foregroundColor(Chika.cream)
                        .padding(16)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        // Page turns have no visible button; these invisible ones carry ⌘[ / ⌘], the modes, ⌥⌘N, ⌘D,
        // ⇧⌘E and ⌘E (the More menu shows the last two but a menu's shortcuts may not fire until it has
        // been opened). Off while editing panels, so the page under the editor stays put.
        .background {
            Group {
                Button("Previous page") { model.turnPage(next: false) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next page") { model.turnPage(next: true) }
                    .keyboardShortcut("]", modifiers: .command)
                ForEach(Array(ReadingMode.allCases.enumerated()), id: \.element) { i, mode in
                    Button(mode.title) { model.setMode(mode) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Button("Next night filter") { settings.nightFilter = settings.nightFilter.next }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Toggle bookmark") { model.toggleBookmark() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Export panel") { exportPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Edit panels") { editPanels() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Read aloud") { toggleReadAloud() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .disabled(editing)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .navigationTitle(model.title)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onCopyCommand { editing ? [] : model.copyItems() }   // Edit > Copy and ⌘C; not the hidden page behind the editor
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space, phases: .down) { press in
            step(press.modifiers.contains(.shift) ? -1 : 1); return .handled
        }
        .onKeyPress(.pageUp) { turn(next: false); return .handled }
        .onKeyPress(.pageDown) { turn(next: true); return .handled }
        // Any step or page change lands un-zoomed, like Android.
        .onChange(of: [model.slots.page, model.slots.step]) {
            withAnimation(ReaderModel.cameraTween) { resetZoom() }
        }
        // The peek holds auto-advance while the editor is open (and not after this window closes mid-edit).
        .onChange(of: editing) { model.editingPanels = editing }
        .onDisappear { model.editingPanels = false; speaker.isOn = false; translator.stop() }
        // Translate (and Read aloud's text) follows the pages on screen once they (and in Panels mode their panels) are in.
        .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled)) { voiceOver = $0 }
        // VoiceOver reads the balloons too, so their text is read with Translate and Read aloud off.
        .onChange(of: [translator.isOn, speaker.isOn, voiceOver, model.waitingForPage, settings.translationTarget, model.rightToLeft,
                       model.pageImages.map(\.page)] as [AnyHashable], initial: true) {
            translator.show(model.waitingForPage ? [] : model.pageImages, of: model.comicURL,
                            revision: model.revision, rtl: model.rightToLeft, target: settings.targetLanguage,
                            aloud: speaker.isOn || voiceOver)
        }
        .translationTask(translator.configuration) { session in await translator.translate(with: session) }
        // Read aloud: each view's balloons, then one step on, like the arrow key; any step starts the new view.
        .onChange(of: [speaker.isOn, aloudKey, aloudLines] as [AnyHashable], initial: true) {
            speaker.update(key: aloudKey, lines: aloudLines, wait: model.mode == .panels && !model.slots.onPanel ? 0.6 : 1.5)
        }
        .onChange(of: settings.speechRate, initial: true) { speaker.rate = settings.speechRate }
        .onChange(of: model.mode) { if model.mode == .scroll { speaker.isOn = false } }
        .onAppear {
            speaker.onDone = { [model, weak speaker] in
                // Blocked here is the end of the book: the view was in, so it is not waiting for detection.
                if model.advance(by: 1) == .blocked { speaker?.isOn = false }
            }
            speaker.isCurrent = { [self] key in key == AnyHashable(aloudKey) }
        }
    }

    private func toggleReadAloud() {
        guard model.mode != .scroll else { NSSound.beep(); return }
        speaker.isOn.toggle()
    }

    /// The view Read aloud is on: a new one interrupts the speech.
    private var aloudKey: [AnyHashable] {
        // The direction too: a flip reorders the lines, so the view starts over rather than skip or repeat one.
        [model.mode, model.visiblePages, model.mode == .panels ? model.slots.step : 0,
         model.mode == .panels ? model.slots.camera : .fullPage, editing, model.rightToLeft]
    }

    /// Read aloud's lines for the view on screen in reading order: in Panels mode the balloons of the
    /// panel on screen (none on a whole-page slot, its panels read them), in Two pages every balloon of
    /// each page, panel by panel. Nil until the view, its panels and its balloons' text are in, or while
    /// editing panels. A page that would not decode has no text, so its view waits and steps on.
    private var aloudLines: [BalloonSpeaker.Line]? {
        guard speaker.isOn, !editing, !model.waitingForPage, !translator.reading, model.imagePages == model.visiblePages else { return nil }
        let panels = model.mode == .panels
        return model.visiblePages.flatMap { page in
            let read = translator.balloons[page] ?? []
            let boxes = panels
                ? BalloonText.balloons(read.map(\.box), inRegion: model.slots.step, of: model.slots.regions ?? [], rightToLeft: model.rightToLeft)
                : BalloonText.balloons(read.map(\.box), of: wholePagePanels(page), rightToLeft: model.rightToLeft)
            return boxes.compactMap { box in
                read.first { $0.box == box }.flatMap {
                    BalloonSpeaker.line($0, page: page, translate: translator.isOn, target: settings.targetLanguage)
                }
            }
        }
    }

    /// Translate's labels for a page, only while Translate is on (Read aloud reads the text without it).
    private func labels(_ page: Int) -> [BalloonTranslator.Balloon] {
        translator.isOn ? translator.balloons[page] ?? [] : []
    }

    /// VoiceOver's elements for a page's balloons in the view on screen: the panel's in Panels mode, the
    /// page's on a whole page and in Two pages.
    private func voiceOverBalloons(_ page: Int) -> [PageAccessibility.Element] {
        guard !editing else { return [] }
        let onPanel = model.mode == .panels && model.slots.onPanel
        return PageAccessibility.elements(translator.balloons[page] ?? [], step: onPanel ? model.slots.step : nil,
                                          of: wholePagePanels(page), rightToLeft: model.rightToLeft,
                                          translate: translator.isOn, target: settings.targetLanguage)
    }

    /// A page's panels in reading order, so its balloons are read panel by panel: the panels on screen in
    /// Panels mode, the stored (or hand-drawn) ones in Two pages; the whole page when none are known.
    private func wholePagePanels(_ page: Int) -> [Panel] {
        (model.mode == .panels ? model.slots.regions : model.knownRegions(page)) ?? [.fullPage]
    }

    /// VoiceOver's label for the page: where the reader is, and whether the view has no text once it is read.
    private var pageAccessibilityLabel: String {
        let read = voiceOver && !model.waitingForPage && !translator.reading && !model.pageImages.isEmpty
        let panel = model.mode == .panels && model.slots.onPanel ? (model.slots.step, model.slots.panelCount) : nil
        return PageAccessibility.label(pages: model.visiblePages, of: model.pageCount, panel: panel,
                                       hasText: read ? model.visiblePages.contains { !voiceOverBalloons($0).isEmpty } : nil)
    }

    /// Read aloud's outline, on the page it is speaking from.
    private func spoken(_ page: Int) -> Panel? {
        speaker.current.flatMap { $0.page == page ? $0.box : nil }
    }

    /// One reading step: a panel, a spread, or (scroll mode) most of a screen.
    private func step(_ delta: Int) {
        guard !editing else { return }
        guard model.mode == .scroll else { model.advance(by: delta); return }
        withAnimation(.easeOut(duration: 0.25)) { scroll.scrollTo(y: max(0, scrollY + CGFloat(delta) * viewport * 0.85)) }
    }

    private func turn(next: Bool) {
        guard !editing else { return }
        model.mode == .scroll ? step(next ? 1 : -1) : model.turnPage(next: next)
    }

    @ViewBuilder
    private func readerBody(size: CGSize) -> some View {
        if model.mode == .scroll {
            ScrollReader(model: model, position: $scroll, offset: $scrollY)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewport = $0 }
        } else {
            pagedBody(size: size)
        }
    }

    private func pagedBody(size: CGSize) -> some View {
        Group {
            if model.mode == .spread { spreadPages(size: size) } else { panelPage(size: size) }
        }
        // topLeading alignment is load-bearing: the bitmap-sized Image makes the ZStack oversized,
        // and a default (.center) frame alignment would shift the image's local origin — the
        // CameraFraming transform assumes local (0,0) sits at the container's top-left corner.
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .overlay { if model.image == nil { ProgressView().tint(Chika.ochre) } }
        // Reticle framing brackets — always drawn while reading (independent of chrome), crimson.
        .overlay { if model.image != nil {
            Reticle(color: Chika.crimson.opacity(0.45), inset: 6, length: 16, stroke: 2).padding(6)
        } }
        .contentShape(Rectangle())
        // Zoomed in, a two-finger swipe is left alone rather than throwing the zoom away with the page.
        .background(SwipeToTurn(rightToLeft: model.rightToLeft) { next in if zoom <= 1 { turn(next: next) } })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pageAccessibilityLabel)
        .accessibilityHint(PageAccessibility.hint)
        // Double-click is declared first so a single click waits for it to be ruled out.
        .onTapGesture(count: 2) { wholePage() }
        .onTapGesture { location in tapZone(x: location.x, width: size.width) }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { zoom = min(max(steadyZoom * $0.magnification, 1), 5) }
                .onEnded { _ in if zoom <= 1.01 { resetZoom() } else { steadyZoom = zoom } }
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { drag in
                    // The comic floats over the background, clamped so it can't be lost off-screen.
                    let raw = CGSize(width: steadyPan.width + drag.translation.width,
                                     height: steadyPan.height + drag.translation.height)
                    pan = clampPan(raw, viewSize: size)
                }
                .onEnded { _ in steadyPan = pan }   // commit the floated / zoomed-pan position
        )
    }

    private func panelPage(size: CGSize) -> some View {
        // The page is a plain Image carried by one animatable transform (CameraFraming) that runs
        // the shared computePageDraw per frame — so stepping between panels TWEENS the camera the
        // way Android's Animatable camera does (a Canvas can't animate; it jump-cuts).
        let camera = model.slots.camera
        let filter = settings.nightFilter
        // Dim darkens around a panel, and the whole page when the whole page shows (nothing is around it).
        let around = filter == .dim && camera != .fullPage
        return ZStack(alignment: .topLeading) {
            if let cg = model.image {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .frame(width: CGFloat(cg.width), height: CGFloat(cg.height))
                    .overlay { BalloonLabels(balloons: labels(model.imagePages.first ?? -1)) }
                    .overlay { SpokenBalloon(box: spoken(model.imagePages.first ?? -1)) }
                    .overlay { BalloonAccessibility(elements: voiceOverBalloons(model.imagePages.first ?? -1)) }
                    // Here dim darkens around the panel instead: drawn in page coordinates under the
                    // same transform, so it stays on the panel through camera tweens, zoom and pan.
                    .modifier(NightFilterEffect(filter: around ? .off : filter))
                    .overlay {
                        if around {
                            OutsideCamera(camera: CGRect(x: CGFloat(camera.left), y: CGFloat(camera.top),
                                                         width: CGFloat(camera.width), height: CGFloat(camera.height)))
                                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                        }
                    }
                    .modifier(CameraFraming(
                        camL: CGFloat(camera.left), camT: CGFloat(camera.top),
                        camR: CGFloat(camera.right), camB: CGFloat(camera.bottom),
                        zoom: zoom, panX: pan.width, panY: pan.height,
                        container: size))
                    .opacity(model.pageAlpha)
            }
        }
    }

    /// Spread mode: the spread's pages side by side (mirrored for right-to-left), fitted together.
    /// Zoom scales about the centre; drag pans within the zoomed overhang.
    private func spreadPages(size: CGSize) -> some View {
        // Zipped before dropping a missing image, so a facing page keeps its own page number.
        let pages = zip(model.imagePages, [model.image, model.facing]).compactMap { page, image in image.map { (page, $0) } }
        return HStack(spacing: 0) {
            ForEach(Array((model.rightToLeft ? pages.reversed() : pages).enumerated()), id: \.offset) { _, page in
                Image(decorative: page.1, scale: 1).resizable().scaledToFit()
                    .overlay { BalloonLabels(balloons: labels(page.0)) }
                    .overlay { SpokenBalloon(box: spoken(page.0)) }
                    .overlay { BalloonAccessibility(elements: voiceOverBalloons(page.0)) }
            }
        }
        .modifier(NightFilterEffect(filter: settings.nightFilter))
        .frame(maxWidth: size.width * 0.98, maxHeight: size.height * 0.98)
        .scaleEffect(zoom)
        .offset(pan)
        .opacity(model.pageAlpha)
        .frame(width: size.width, height: size.height)
    }

    // Top-bar status line, matching Android: "Page X/Y · panel N/M" / "· full page" / "· detecting…".
    private var pageStatus: String {
        pagePosition + (translator.status.map { " · " + $0 } ?? "") + (speaker.isOn ? " · reading aloud" : "")
    }

    private var pagePosition: String {
        if model.mode == .scroll { return "Page \(model.slots.page + 1)/\(model.pageCount) · scroll" }
        if model.mode == .spread {
            let pages = model.visiblePages.map { "\($0 + 1)" }.joined(separator: "–")
            return "Page\(model.visiblePages.count > 1 ? "s" : "") \(pages)/\(model.pageCount) · two pages"
        }
        let prefix = "Page \(model.slots.page + 1)/\(model.pageCount) · "
        let edited = model.pageEdited ? " · edited" : ""
        if model.detecting { return prefix + "detecting…" }
        if model.slots.onPanel { return prefix + "panel \(model.slots.step + 1)/\(model.slots.panelCount)" + edited }
        return prefix + "full page" + edited
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
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close (Esc)")
            .accessibilityLabel("Back to library")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.archivo(14, weight: 800)).foregroundColor(Chika.cream).lineLimit(1)
                Text(pageStatus).font(.archivo(9)).tracking(1.4).foregroundColor(Chika.creamMuted)
            }
            Spacer()
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").foregroundColor(Chika.cream).frame(width: 36, height: 38)
            }
            .help("Previous panel (Left Arrow)")
            .accessibilityLabel("Previous panel")
            Button { step(1) } label: {
                Image(systemName: "chevron.right").foregroundColor(Chika.cream).frame(width: 36, height: 38)
            }
            .help("Next panel (Right Arrow)")
            .accessibilityLabel("Next panel")
            // Show whole page (Android's ZoomOutMap): plain icon, always enabled (no-op on full page).
            Button { wholePage() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Chika.cream)
                    .frame(width: 38, height: 38)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Show whole page (⌘0)")
            .accessibilityLabel("Show whole page")
            .opacity(model.mode == .panels ? 1 : 0)
            .disabled(model.mode != .panels)
            Menu {
                Button(marked ? "Remove bookmark" : "Add bookmark") { model.toggleBookmark() }
                if !model.bookmarks.isEmpty { Divider() }
                ForEach(model.bookmarks, id: \.self) { mark in
                    Button("Page \(mark.page + 1)" + (mark.step >= 0 ? " · panel \(mark.step + 1)" : "")) {
                        model.goToPage(mark.page, step: mark.step)
                        // The strip only follows page changes; this also lands on the top of the current page.
                        if model.mode == .scroll { scroll.scrollTo(id: mark.page, anchor: .top) }
                    }
                }
            } label: {
                Image(systemName: marked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Chika.cream)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Bookmarks: mark this spot (⌘D) or jump back to one")
            .accessibilityLabel("Bookmarks")
            .accessibilityValue(marked ? "Bookmarked" : "Not bookmarked")
            Menu {
                Picker("Reading mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(ReadingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: ["panels": "rectangle.split.2x2", "spread": "book", "scroll": "scroll"][model.mode.rawValue]!)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Chika.cream)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reading mode: ⌘1 panels, ⌘2 two pages, ⌘3 scroll")
            .accessibilityLabel("Reading mode")
            Menu {
                Picker("Night filter", selection: $settings.nightFilter) {
                    ForEach(NightFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: settings.nightFilter == .off ? "moon" : "moon.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Chika.cream)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Night filter: invert, sepia or dim the pages (⌥⌘N cycles)")
            .accessibilityLabel("Night filter")
            .accessibilityValue(settings.nightFilter.title)
            Button { translator.isOn.toggle() } label: {
                Image(systemName: translator.isOn ? "character.bubble.fill" : "character.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Chika.cream)
                    .frame(width: 38, height: 38)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .help(model.mode == .scroll ? "Translate works in Panels and Two pages" : "Translate the speech balloons (⇧⌘T); hover one for the original")
            .accessibilityLabel("Translate")
            .accessibilityValue(translator.isOn ? "On" : "Off")
            .disabled(model.mode == .scroll)
            Button { toggleReadAloud() } label: {
                Image(systemName: speaker.isOn ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Chika.cream)
                    .frame(width: 38, height: 38)
            }
            .help(model.mode == .scroll ? "Read aloud works in Panels and Two pages"
                  : "Read the balloons aloud and step on by itself (⇧⌘R); speed in Settings")
            .accessibilityLabel("Read aloud")
            .accessibilityValue(speaker.isOn ? "On" : "Off")
            .disabled(model.mode == .scroll)
            DirectionChip(rightToLeft: model.rightToLeft) { model.toggleDirection() }
            Button { openWindow(id: "peek", value: model.comicURL) } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Chika.cream)
                    .frame(width: 38, height: 38)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Peek: float the current panel (⌘⇧P)")
            .accessibilityLabel("Peek")
            Menu {
                // Sends Edit > Copy, so it lands in onCopyCommand like ⌘C does.
                Button("Copy Panel") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Export Panel…") { exportPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Edit Panels") { editPanels() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.canEditPanels)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Chika.cream)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: copy the panel (⌘C), export it as a PNG (⇧⌘E) or edit this page's panels (⌘E)")
            .accessibilityLabel("More")
        }
        .buttonStyle(.plain)
        .padding(.leading, 12).padding(.trailing, 6).padding(.top, 8).padding(.bottom, 18)
        .background(LinearGradient(colors: [Chika.ink.opacity(0.94), .clear],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack {
                // On the last page, the next issue of the series (ComicInfo.xml) replaces the hint.
                if model.onLastPage, let next = library.nextIssue(after: model.comicURL) {
                    Button {
                        openWindow(id: "reader", value: next)
                        dismiss()
                    } label: {
                        Label("NEXT ISSUE: \(next.deletingPathExtension().lastPathComponent.uppercased())", systemImage: "arrow.right")
                            .font(.anton(12)).tracking(1).foregroundColor(Chika.cream)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Chika.crimson).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Open the next issue (Return)")
                } else {
                    Text("ARROW KEYS TO READ").font(.anton(12)).tracking(2).foregroundColor(Chika.creamMuted)
                }
                Spacer()
                PageCoin(page: (scrubbing ? Int(scrub.rounded()) : model.slots.page) + 1, total: model.pageCount)
            }
            Slider(
                value: $scrub,
                in: 0...Double(max(model.pageCount - 1, 1)),
                onEditingChanged: { editing in
                    if editing { scrubbing = true }
                    else {
                        scrubbing = false
                        model.goToPage(Int(scrub.rounded()))
                    }
                }
            )
            .tint(Chika.ochre)
            .accessibilityLabel("Page")
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
        .background(LinearGradient(colors: [.clear, Chika.ink.opacity(0.97)],
                                   startPoint: .top, endPoint: .bottom))
        // Keep the scrubber in sync with programmatic page changes (clicks, keys, peek) while not scrubbing.
        .onChange(of: model.slots.page, initial: true) { _, page in if !scrubbing { scrub = Double(page) } }
    }

    // Click zones, matching Android: left third steps back, right third steps forward (panels are
    // pre-ordered in reading direction, so this is RTL-agnostic). The middle third does nothing:
    // on the Mac the chrome is always shown.
    private func tapZone(x: CGFloat, width: CGFloat) {
        if x < width / 3 { model.advance(by: -1) }
        else if x > width * 2 / 3 { model.advance(by: 1) }
    }

    /// Export Panel… (⇧⌘E): what is being read, saved as a PNG where the user picks.
    private func exportPanel() {
        guard let image = model.readingImage() else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(model.title) p\(model.here.page + 1).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Opens the panel editor (⌘E) on the current page; Panels mode only, once the page and its panels are in.
    private func editPanels() {
        guard model.canEditPanels else { NSSound.beep(); return }
        editing = true
    }

    /// Whole page, also dropping any manual zoom (even when already on the whole page).
    private func wholePage() {
        withAnimation(ReaderModel.cameraTween) { resetZoom() }
        model.showWholePage()
    }

    private func resetZoom() {
        zoom = 1; steadyZoom = 1; pan = .zero; steadyPan = .zero
    }

    // Clamps free-pan so a floated/zoomed page can't be lost off-screen: horizontal "cover" (never
    // exposes side background), vertical "float" keeping ≥15% on screen — Android's clampPan ported
    // onto the same computePageDraw transform (scale about centre, then translate by pan).
    private func clampPan(_ raw: CGSize, viewSize: CGSize) -> CGSize {
        if model.mode == .spread {
            let x = viewSize.width * (zoom - 1) / 2, y = viewSize.height * (zoom - 1) / 2
            return CGSize(width: min(max(raw.width, -x), x), height: min(max(raw.height, -y), y))
        }
        guard let image = model.image else { return raw }
        let cw = viewSize.width, ch = viewSize.height
        let draw = computePageDraw(
            camera: model.slots.camera, bitmapW: image.width, bitmapH: image.height,
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
}

/// A two-finger horizontal swipe over the page turns it (a spread in Two pages), once per gesture.
/// SwiftUI has no swipe on the Mac, so a local monitor reads the window's scroll events; it never
/// takes clicks or swallows events, so the click zones, pinch and drag work as before.
private struct SwipeToTurn: NSViewRepresentable {
    let rightToLeft: Bool
    let turn: (Bool) -> Void

    func makeNSView(context: Context) -> SwipeView { SwipeView() }

    func updateNSView(_ view: SwipeView, context: Context) {
        view.rightToLeft = rightToLeft
        view.turn = turn
    }

    final class SwipeView: NSView {
        var rightToLeft = false
        var turn: (Bool) -> Void = { _ in }
        private var swipe = SwipeTurn()
        private var tracking = false
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks stay with the page's gestures

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = window == nil ? nil : NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.scrolled(event)
                return event
            }
        }

        private func scrolled(_ event: NSEvent) {
            // Fingers on a trackpad only: a mouse wheel has no phase, and momentum after they lift is no swipe.
            guard event.window === window, event.momentumPhase.isEmpty else { return }
            if event.phase == .began {
                tracking = bounds.contains(convert(event.locationInWindow, from: nil))
                swipe.begin()
            }
            guard tracking, event.phase == .began || event.phase == .changed else { return }
            // Natural scrolling reports the fingers' own direction; without it the deltas are flipped.
            let fingers: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            if let next = swipe.moved(dx: Float(event.scrollingDeltaX * fingers), dy: Float(event.scrollingDeltaY * fingers),
                                      rightToLeft: rightToLeft) { turn(next) }
        }
    }
}

/// Scroll mode (webtoons): every page in one vertical strip at the window's width, loaded as it
/// nears the screen. The page crossing the top edge is the reading position.
private struct ScrollReader: View {
    @ObservedObject var model: ReaderModel
    @Binding var position: ScrollPosition
    @Binding var offset: CGFloat
    @State private var top = 0
    // Only a moving strip reports its top page: layout and instant jumps (the first layout puts
    // page 1 at the top before the jump to the saved page) must not move the reading position.
    @State private var phase = ScrollPhase.idle

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        ScrollPage(model: model, index: index, width: geo.size.width) { page in
                            guard phase != .idle else { return }
                            top = page
                            model.scrolled(to: page)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition($position, anchor: .top)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in offset = y }
            .onScrollPhaseChange { _, new in phase = new }
        }
        .onAppear { top = model.slots.page; position.scrollTo(id: top, anchor: .top) }
        // Page jumps (scrubber, ⌘[ ⌘], the peek window) scroll the strip to that page.
        .onChange(of: model.slots.page) { _, page in
            if page != top { top = page; position.scrollTo(id: page, anchor: .top) }
        }
    }
}

private struct ScrollPage: View {
    let model: ReaderModel   // not observed: a row only needs the page loader
    let index: Int
    let width: CGFloat
    let atTop: (Int) -> Void
    @EnvironmentObject private var settings: ChikaSettings
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().modifier(NightFilterEffect(filter: settings.nightFilter))
            } else {
                ProgressView().tint(Chika.ochre)
            }
        }
        .frame(width: width, height: width * aspect)
        .task(id: index) { image = await model.scrollImage(index) }
        .onGeometryChange(for: Bool.self, of: { geo in
            let frame = geo.frame(in: .scrollView)
            return frame.minY <= 1 && frame.maxY > 1
        }) { crossing in if crossing { atTop(index) } }
    }

    // Until it loads, a page is assumed to have a typical comic page's shape.
    private var aspect: CGFloat { image.map { CGFloat($0.height) / CGFloat(max($0.width, 1)) } ?? 1.45 }
}

/// Frames the page exactly like the shared computePageDraw (contain-fit the camera at [fill]),
/// then layers the user's pinch zoom / pan about the container centre — all as ONE animatable
/// transform. Because the camera rect itself is the animatable data, SwiftUI tweening it between
/// panels reproduces Android's `Animatable(camera, PanelConverter)` motion: the framing math runs
/// on every interpolated camera, not on interpolated screen rects.
struct CameraFraming: GeometryEffect {
    var camL: CGFloat, camT: CGFloat, camR: CGFloat, camB: CGFloat
    var zoom: CGFloat = 1
    var panX: CGFloat = 0, panY: CGFloat = 0
    var container: CGSize
    var fill: CGFloat = 0.98

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
        let draw = computePageDraw(
            camera: Panel(left: Float(camL), top: Float(camT), right: Float(camR), bottom: Float(camB)),
            bitmapW: Int(max(size.width, 1)),
            bitmapH: Int(max(size.height, 1)),
            containerW: Float(container.width),
            containerH: Float(container.height),
            fill: Float(fill)
        )
        let s = CGFloat(draw.scaledWidth) / max(size.width, 1)
        let cx = container.width / 2, cy = container.height / 2
        let left = cx + (CGFloat(draw.left) - cx) * zoom + panX
        let top = cy + (CGFloat(draw.top) - cy) * zoom + panY
        return ProjectionTransform(
            CGAffineTransform(translationX: left, y: top).scaledBy(x: s * zoom, y: s * zoom))
    }
}

/// A night filter's colour change, for page pixels only (reader and peek). Dim darkens the whole
/// page; on a panel in Panels mode OutsideCamera dims around it instead.
struct NightFilterEffect: ViewModifier {
    let filter: NightFilter

    func body(content: Content) -> some View {
        switch filter {
        case .off: content
        case .invert: content.colorInvert().hueRotation(.degrees(180))   // dark pages, hues kept
        case .sepia: content.grayscale(1).colorMultiply(Color(hex: 0xF0D4A8))
        case .dim: content.colorMultiply(Color(white: 0.6))   // scales, so dark detail survives
        }
    }
}

/// The page outside the camera, as an even-odd path in page coordinates. Animatable, so it tweens
/// with the camera instead of jumping to the next panel.
struct OutsideCamera: Shape {
    var camera: CGRect   // unit page coordinates, like Panel

    var animatableData: CGRect.AnimatableData {
        get { camera.animatableData }
        set { camera.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(CGRect(x: rect.minX + camera.minX * rect.width, y: rect.minY + camera.minY * rect.height,
                            width: camera.width * rect.width, height: camera.height * rect.height))
        return path
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
        .help("Reading direction")
        .accessibilityLabel(rightToLeft ? "Reading right to left" : "Reading left to right")
    }
}
