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
            .onAppear { readers.attach(comicURL) }
            .onDisappear { readers.detach(comicURL) }
    }
}

private struct PeekContent: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var settings: ChikaSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hovering = false
    @State private var opacity = 1.0
    @State private var playing = false
    @AppStorage("chika.peek.autoAdvanceSeconds") private var seconds = 5
    @State private var window: NSWindow?
    @FocusState private var focused: Bool

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
        .background(settings.ground)
        .overlay(alignment: .top) { bar.opacity(hovering ? 1 : 0) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in withAnimation(.easeOut(duration: 0.2)) { hovering = inside } }
        .background(PeekWindowConfigurator(aspect: aspect, opacity: opacity, window: $window))
        .frame(minWidth: 240, idealWidth: 420, minHeight: 160, idealHeight: 420 * aspect.height / aspect.width)
        .navigationTitle(model.title)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onCopyCommand { model.copyItems(peek: true) }   // Edit > Copy and ⌘C: the panel shown here
        .onKeyPress(.leftArrow) { model.advance(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.advance(by: 1); return .handled }
        .onKeyPress(.space, phases: .down) { press in
            model.advance(by: press.modifiers.contains(.shift) ? -1 : 1); return .handled
        }
        .onKeyPress("p", phases: .down) { _ in playing.toggle(); return .handled }
        // Any move, manual or automatic (or a new dwell time), changes the id and so restarts the wait. The
        // pointer over the peek or the reader's panel editor open pauses it; the wait starts again after.
        .task(id: playing && !hovering && !model.editingPanels ? [model.slots.page, model.slots.step, seconds] : []) {
            try? await autoAdvance()
        }
        // Out of sight (minimized, Chika hidden, the screen locked, asleep or under the screen saver) the task
        // keeps running, so stop rather than read on unseen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let w = note.object as? NSWindow, w === window, !w.occlusionState.contains(.visible) { playing = false }
        }
    }

    /// While playing: once the page on screen has its image and panels, wait the dwell, then step once.
    /// Stops at the end of the book.
    private func autoAdvance() async throws {
        guard playing else { return }
        // shortcut: each auto step saves progress and refreshes the library window, batch saves while playing if that shows up
        while model.waitingForPage { try await Task.sleep(for: .milliseconds(300)) }
        // Clamped: the stored value can be edited outside the app, and 0 would race to the last page.
        try await Task.sleep(for: .seconds(min(max(seconds, 2), 20)))
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
            glassCircle("Minimize", "minus", help: "Minimize") { window?.miniaturize(nil) }
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
            Button { model.advance(by: -1) } label: { Label("Previous panel", systemImage: "chevron.left") }
                .help("Previous panel (Left Arrow)")
            Button { playing.toggle() } label: {
                Label(playing ? "Pause auto-advance" : "Auto-advance", systemImage: playing ? "pause.fill" : "play.fill")
            }
                .help(playing ? "Pause auto-advance (P)" : "Auto-advance: next panel every \(seconds) s (P)")
            Button { model.advance(by: 1) } label: { Label("Next panel", systemImage: "chevron.right") }
                .help("Next panel (Right Arrow)")
            if full {
                Stepper(value: $seconds, in: 2...20) { Text("\(seconds) s") }
                    .labelsHidden()
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
        .padding(.horizontal, 12).frame(height: 28)
        .liquidGlass(Capsule())
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

/// Reaches the peek's NSWindow: follows you across Spaces and over full-screen apps, stays up when
/// Chika is in the background, drags by its content, keeps the current panel's aspect while
/// resizing, fades with the opacity slider, and opens where it was last left (PeekPlacement).
private struct PeekWindowConfigurator: NSViewRepresentable {
    let aspect: CGSize
    let opacity: Double
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView { NSView() }

    func makeCoordinator() -> PeekPlacement { PeekPlacement() }

    static func dismantleNSView(_ view: NSView, coordinator: PeekPlacement) { coordinator.stop() }

    func updateNSView(_ view: NSView, context: Context) {
        let placement = context.coordinator
        // The view joins its window after this first update, so look it up on the next turn.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if self.window !== window {   // set once
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
                window.setContentSize(CGSize(width: 420, height: 420 * aspect.height / aspect.width))
                if !placement.restore(window) { window.center() }
                placement.watch(window)
                self.window = window
            }
            if window.aspectRatio != aspect {
                // A new panel shape: resize to it, keeping the current width, and a window in a corner
                // in that corner (the resize alone keeps the bottom-left).
                window.aspectRatio = aspect
                let area = window.screen?.visibleFrame
                let corner = area.flatMap { WindowSnap.corner(near: window.frame, in: $0, reach: 1) }
                let w = window.frame.width
                window.setContentSize(CGSize(width: w, height: w * aspect.height / aspect.width))
                if let area, let corner { window.setFrameOrigin(WindowSnap.origin(corner, size: window.frame.size, in: area)) }
            }
            window.alphaValue = opacity
        }
    }
}

/// The peek's place on screen: dropped near a corner of its screen it snaps into it, and where it
/// settles is saved with that screen, so the next peek opens there (centred if that screen is gone).
@MainActor
private final class PeekPlacement {
    private static let frameKey = "chika.peek.frame", screenKey = "chika.peek.screen"
    private var observer: NSObjectProtocol?
    private var settling = false

    /// Puts the window where it was last left; false if there is no such place on a screen now.
    func restore(_ window: NSWindow) -> Bool {
        let defaults = UserDefaults.standard
        guard let saved = defaults.string(forKey: Self.frameKey).map(NSRectFromString),
              let id = defaults.string(forKey: Self.screenKey),
              let screen = NSScreen.screens.first(where: { $0.uuid == id }),
              let origin = WindowSnap.restore(saved, size: window.frame.size, in: screen.visibleFrame) else { return false }
        window.setFrameOrigin(origin)
        return true
    }

    func watch(_ window: NSWindow) {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window,
                                                          queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated { if let window { self?.settle(window) } }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// The window moved: once the mouse button is up (a drag may report its moves before the drop),
    /// snap it into a corner it is near and save where it is.
    private func settle(_ window: NSWindow) {
        guard !settling else { return }
        settling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
            guard let self, let window else { return }
            settling = false
            if NSEvent.pressedMouseButtons & 1 != 0 { settle(window); return }
            guard let screen = window.screen else { return }
            var frame = window.frame
            if let corner = WindowSnap.corner(near: frame, in: screen.visibleFrame) {
                frame.origin = WindowSnap.origin(corner, size: frame.size, in: screen.visibleFrame)
                if frame != window.frame { window.setFrame(frame, display: true, animate: true) }
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
