import SwiftUI
import AppKit
import ChikaCore

/// Floating "peek" window: only the current panel of the comic's shared ReaderModel, no chrome, so
/// you can keep reading in a small always-on-top window while working in another app. The window has
/// no border; on hover its controls fade in over the top as floating glass pieces: minimize, panel
/// steps, auto-advance, window opacity, and expand back to the full reader.
struct PeekView: View {
    let comicURL: URL
    @EnvironmentObject private var readers: ReaderModels
    @EnvironmentObject private var settings: ChikaSettings

    var body: some View {
        PeekContent(model: readers.model(for: comicURL, settings: settings))
            .onAppear { readers.attach(comicURL); ShortcutTarget.peeks.insert(comicURL) }
            .onDisappear { readers.detach(comicURL); ShortcutTarget.peeks.remove(comicURL) }
    }
}

private struct PeekContent: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var settings: ChikaSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hovering = false
    @AppStorage("chika.peek.opacity") private var opacity = 1.0
    @State private var playing = false
    @AppStorage("chika.peek.autoAdvanceSeconds") private var seconds = 5
    @State private var window = WeakWindow()
    @FocusState private var focused: Bool
    @Environment(\.appearsActive) private var appearsActive
    @State private var voiceOver = NSWorkspace.shared.isVoiceOverEnabled

    static let minimum = CGSize(width: 240, height: 160)

    // The current camera's size in bitmap pixels: its ratio is the window's aspect.
    private var aspect: CGSize {
        guard let cg = model.image else { return CGSize(width: 1, height: 1) }
        if model.mode == .spread, let facing = model.facing {   // both pages at the first page's height
            return CGSize(width: CGFloat(cg.width) + CGFloat(facing.width) * CGFloat(cg.height) / CGFloat(facing.height),
                          height: CGFloat(cg.height))
        }
        let camera = model.slots.camera
        return CGSize(width: CGFloat(camera.width) * CGFloat(cg.width),
                      height: max(CGFloat(camera.height) * CGFloat(cg.height), 1))
    }

    /// Auto-advance may step: playing, with the pointer off the peek and the reader's panel editor shut.
    private var mayAdvance: Bool { playing && !hovering && !model.editingPanels }

    /// VoiceOver's label for the peek: where the reader is, as the reader's page says it.
    private var pageLabel: String {
        let panel = model.mode == .panels && model.slots.onPanel ? (model.slots.step, model.slots.panelCount) : nil
        return PageAccessibility.label(pages: model.visiblePages, of: model.pageCount, panel: panel, hasText: nil)
    }

    /// The size the window opens at: 420 pt wide, narrower if the screen is too short for the shape.
    private var ideal: CGSize {
        WindowSnap.size(aspect, width: 420, in: NSScreen.main?.visibleFrame ?? .infinite, minimum: Self.minimum)
    }

    var body: some View {
        GeometryReader { geo in
            let camera = model.slots.camera
            ZStack(alignment: .topLeading) {
                if model.mode == .spread {
                    // Two pages: the whole spread (mirrored for right-to-left), as the reader shows it.
                    let pages = [model.image, model.facing].compactMap { $0 }
                    HStack(spacing: 0) {
                        ForEach(Array((model.rightToLeft ? pages.reversed() : pages).enumerated()), id: \.offset) { _, page in
                            Image(decorative: page, scale: 1).resizable().scaledToFit()
                        }
                    }
                    .modifier(NightFilterEffect(filter: settings.nightFilter))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(model.pageAlpha)
                } else if let cg = model.image {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .frame(width: CGFloat(cg.width), height: CGFloat(cg.height))
                        .modifier(NightFilterEffect(filter: settings.nightFilter))   // peek dims the whole panel
                        .modifier(CameraFraming(
                            camL: CGFloat(camera.left), camT: CGFloat(camera.top),
                            camR: CGFloat(camera.right), camB: CGFloat(camera.bottom),
                            container: geo.size, fill: 1))
                        .opacity(model.pageAlpha)
                }
            }
            // topLeading: CameraFraming assumes the image's local origin is the container's corner.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .accessibilityElement()
        .accessibilityLabel(pageLabel)
        .accessibilityHint(PageAccessibility.hint)
        .background(settings.ground)
        .opacity(min(max(opacity, 0.4), 1))   // the panel only, so the hover controls stay easy to find
        // Always shown under VoiceOver, which has no pointer to hover with.
        .overlay(alignment: .top) { bar.opacity(hovering || voiceOver ? 1 : 0) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in withAnimation(.easeOut(duration: 0.2)) { hovering = inside } }
        .background(PeekWindowConfigurator(aspect: aspect, window: window))
        .frame(minWidth: Self.minimum.width, idealWidth: ideal.width, minHeight: Self.minimum.height, idealHeight: ideal.height)
        // The hidden title bar's safe area would leave an empty strip above the panel.
        .ignoresSafeArea()
        .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled)) { voiceOver = $0 }
        .navigationTitle(model.title)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true; ShortcutTarget.windowOpened(model)
            // Scroll decodes the page only while a peek is open: catch up with where the strip was scrolled.
            if model.mode == .scroll, model.imagePages != model.visiblePages { model.goToPage(model.slots.page) }
        }
        .onDisappear { ShortcutTarget.windowClosed(model) }
        .onChange(of: appearsActive) { if appearsActive { ShortcutTarget.windowActivated(model) } }   // as the reader does
        .onCopyCommand { model.copyItems(peek: true) }   // Edit > Copy and ⌘C: the panel shown here
        .onKeyPress(.leftArrow) { model.advance(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.advance(by: 1); return .handled }
        .onKeyPress(.space, phases: .down) { press in
            model.advance(by: press.modifiers.contains(.shift) ? -1 : 1); return .handled
        }
        .onKeyPress("p", phases: .down) { _ in playing.toggle(); return .handled }
        // Any move, manual or automatic (or a new dwell time), changes the id and so restarts the wait. The
        // pointer over the peek or the reader's panel editor open pauses it; the wait starts again after.
        .task(id: mayAdvance ? [model.slots.page, model.slots.step, seconds] : []) {
            try? await autoAdvance()
        }
        // Out of sight (minimized, Chika hidden, the screen locked, asleep or under the screen saver) the task
        // keeps running, so stop rather than read on unseen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let w = note.object as? NSWindow, w === window.value, !w.occlusionState.contains(.visible) { playing = false }
        }
    }

    /// While playing: once the page on screen has its image and panels, wait the dwell, then step once.
    /// Stops at the end of the book.
    private func autoAdvance() async throws {
        // The id going to [] (pointer in, editor open) restarts this task too, which must not step then.
        guard mayAdvance else { return }
        // shortcut: each auto step saves progress and refreshes the library window, batch saves while playing if that shows up
        while model.waitingForPage { try await Task.sleep(for: .milliseconds(300)) }
        // Clamped: the stored value can be edited outside the app, and 0 would race to the last page.
        try await Task.sleep(for: .seconds(min(max(seconds, 2), 20)))
        guard mayAdvance else { return }
        while model.advance(by: 1) == .blocked {
            // Blocked while a page reloads under the same slot (a mode change) retries shortly; blocked
            // otherwise is the end of the book or a comic that failed to open.
            guard model.waitingForPage else { playing = false; return }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Hover controls floating over the panel as separate glass pieces, no bar: minimize on the left,
    /// reading controls in the middle (the stepper and opacity drop out when the window is narrow),
    /// back to the full reader on the right.
    private var bar: some View {
        HStack(alignment: .center, spacing: 8) {
            glassCircle("Minimize", "minus", help: "Minimize") { window.value?.miniaturize(nil) }
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                readingControls(full: true)
                readingControls(full: false)
            }
            Spacer(minLength: 0)
            glassCircle("Open full reader", "arrow.up.left.and.arrow.down.right", help: "Back to the full reader") {
                openWindow(id: "reader", value: model.comicURL)
                dismissWindow(id: "peek", value: model.comicURL)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(Chika.cream)
        .padding(8)
        .environment(\.colorScheme, .dark)   // dark glass keeps the icons readable over white pages
    }

    private func readingControls(full: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {   // the buttons' cells space them
                barButton("Previous panel", "chevron.left", help: "Previous panel (Left Arrow)") { model.advance(by: -1) }
                barButton(playing ? "Pause auto-advance" : "Auto-advance", playing ? "pause.fill" : "play.fill",
                          help: playing ? "Pause auto-advance (P)" : "Auto-advance: next panel every \(seconds) s (P)") { playing.toggle() }
                barButton("Next panel", "chevron.right", help: "Next panel (Right Arrow)") { model.advance(by: 1) }
            }
            if full {
                Stepper(value: $seconds, in: 2...20) { Text("\(seconds) s").monospacedDigit() }
                    .controlSize(.mini)
                    .help("Seconds per panel when auto-advancing: \(seconds) s")
                    .accessibilityLabel("Seconds per panel")
                    .accessibilityValue("\(seconds) seconds")
                Slider(value: $opacity, in: 0.4...1)
                    .controlSize(.mini)
                    .tint(Chika.ochre)
                    .frame(width: 64)
                    .help("Window opacity")
                    .accessibilityLabel("Window opacity")
            }
        }
        .padding(.leading, 4).padding(.trailing, full ? 12 : 4).frame(height: 28)
        .liquidGlass(Capsule())
    }

    /// A reading control whose whole cell takes the click, not just its few-point glyph.
    private func barButton(_ title: String, _ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(width: 22, height: 28).contentShape(Rectangle()) }
            .help(help)
    }

    private func glassCircle(_ title: String, _ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(width: 28, height: 28).contentShape(Circle()) }
            .liquidGlass(Circle())
            .help(help)
    }
}

private extension View {
    /// Liquid Glass on macOS 26; a frosted material on macOS 15.
    @ViewBuilder func liquidGlass(_ shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

/// A view's window (the peek's, a reader's), held weakly: the window owns the view's state, so a strong
/// hold would keep every closed window's view alive (and a peek resizing with the shared model).
final class WeakWindow {
    weak var value: NSWindow?
}

/// Reaches the peek's NSWindow: follows you across Spaces and over full-screen apps, stays up when
/// Chika is in the background, drags by its content, keeps the current panel's aspect while
/// resizing, and opens where it was last left (PeekPlacement).
private struct PeekWindowConfigurator: NSViewRepresentable {
    let aspect: CGSize
    let window: WeakWindow

    func makeNSView(context: Context) -> NSView { NSView() }

    func makeCoordinator() -> PeekPlacement { PeekPlacement() }

    static func dismantleNSView(_ view: NSView, coordinator: PeekPlacement) { coordinator.stop() }

    func updateNSView(_ view: NSView, context: Context) {
        let placement = context.coordinator
        // The view joins its window after this first update, so look it up on the next turn.
        DispatchQueue.main.async {
            guard let window = view.window, let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            if self.window.value !== window {   // set once
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.hidesOnDeactivate = false
                window.isMovableByWindowBackground = true
                // Titled (a borderless window never takes keys: arrows, Space, P, ⌘C), with its title bar
                // and buttons invisible so only the panel shows.
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isOpaque = false
                window.backgroundColor = .clear   // the rounded panel, not a square window behind it
                for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(button)?.isHidden = true
                }
                window.hasShadow = true
                // Start small whatever size the window system first gave it, where it was last left (else centred).
                window.setContentSize(WindowSnap.size(aspect, width: 420, in: area, minimum: PeekContent.minimum))
                if !placement.restore(window) { window.center() }
                placement.watch(window)
                self.window.value = window
            }
            window.aspectRatio = aspect
            // The panel's shape at the current width, checked against the window's real size rather than the
            // aspect last set, which a resize from elsewhere (SwiftUI's own, around a mode change) leaves stale.
            let size = WindowSnap.size(aspect, width: window.frame.width, in: area, minimum: PeekContent.minimum)
            let now = window.contentRect(forFrameRect: window.frame).size
            guard !window.inLiveResize, abs(now.width - size.width) > 0.5 || abs(now.height - size.height) > 0.5 else { return }
            let top = window.frame.maxY
            window.setContentSize(size)
            window.setFrameOrigin(CGPoint(x: window.frame.minX, y: top - window.frame.height))   // grows down, as windows do
            placement.place(window)
        }
    }
}

/// The peek's place on screen: dropped near a corner of its screen it snaps into it and stays there
/// through every resize, and where it settles is saved with that screen, so the next peek opens there
/// (centred if that screen is gone).
@MainActor
private final class PeekPlacement {
    private static let frameKey = "chika.peek.frame", screenKey = "chika.peek.screen"
    private var observers: [NSObjectProtocol] = []
    private var settling = false
    /// The corner it was dropped or reopened in. Remembered, not read off the frame: a resize moves the
    /// frame out of the corner before it is put back.
    private var corner: WindowSnap.Corner?
    /// The pending move was the user's (a drag or an edge resize), so it may pick a new corner.
    private var dropped = false

    /// Puts the window where it was last left; false if there is no such place on a screen now.
    func restore(_ window: NSWindow) -> Bool {
        let defaults = UserDefaults.standard
        guard let saved = defaults.string(forKey: Self.frameKey).map(NSRectFromString),
              let id = defaults.string(forKey: Self.screenKey),
              let screen = NSScreen.screens.first(where: { $0.uuid == id }),
              let origin = WindowSnap.restore(saved, size: window.frame.size, in: screen.visibleFrame) else { return false }
        corner = WindowSnap.corner(near: saved, in: screen.visibleFrame, reach: 1)
        window.setFrameOrigin(origin)
        return true
    }

    func watch(_ window: NSWindow) {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ act: @escaping (PeekPlacement, NSWindow) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let self, let window { act(self, window) } }
            }
        }
        observers = [
            on(NSWindow.didMoveNotification) { placement, window in
                if NSEvent.pressedMouseButtons & 1 != 0 { placement.dropped = true }
                placement.settle(window)
            },
            on(NSWindow.didEndLiveResizeNotification) { placement, window in placement.dropped = true; placement.settle(window) },
            // Resized by a new panel or by SwiftUI (not the user's drag): back in its corner, or on screen.
            on(NSWindow.didResizeNotification) { placement, window in if !window.inLiveResize { placement.place(window) } },
        ]
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// In its corner, or (in none) pulled back inside its screen, so it never grows off the bottom.
    func place(_ window: NSWindow) {
        guard let area = window.screen?.visibleFrame else { return }
        let origin = corner.map { WindowSnap.origin($0, size: window.frame.size, in: area) }
            ?? WindowSnap.restore(window.frame, size: window.frame.size, in: area)
        if let origin, origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    /// The window moved: once the mouse button is up (a drag may report its moves before the drop),
    /// a drop picks the corner it is near (or none) and snaps into it; then save where it is.
    private func settle(_ window: NSWindow) {
        guard !settling else { return }
        settling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
            guard let self, let window else { return }
            settling = false
            if NSEvent.pressedMouseButtons & 1 != 0 { settle(window); return }
            guard let screen = window.screen else { return }
            var frame = window.frame
            if dropped {
                dropped = false
                corner = WindowSnap.corner(near: frame, in: screen.visibleFrame)
                if let corner {
                    frame.origin = WindowSnap.origin(corner, size: frame.size, in: screen.visibleFrame)
                    if frame != window.frame { window.setFrame(frame, display: true, animate: true) }
                }
            }
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
            UserDefaults.standard.set(screen.uuid, forKey: Self.screenKey)
        }
    }
}

private extension NSScreen {
    /// The display's UUID: unlike its display number it survives reboots and replugging.
    var uuid: String? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
