import SwiftUI
import AppKit
import ChikaCore

/// Floating "peek" window: only the current panel of the comic's shared ReaderModel, no chrome, so
/// you can keep reading in a small always-on-top window while working in another app. A bar fades
/// in on hover with panel steps, auto-advance, window opacity, minimize, and expand back to the full reader.
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
        .overlay(alignment: .bottom) { bar.opacity(hovering ? 1 : 0) }
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
        // Any move, manual or automatic (or a new dwell time), changes the id and so restarts the wait.
        .task(id: playing ? [model.slots.page, model.slots.step, seconds] : []) { try? await autoAdvance() }
    }

    /// While playing: wait the dwell, then step once. Stops at the end of the book.
    private func autoAdvance() async throws {
        guard playing else { return }
        // Clamped: the stored value can be edited outside the app, and 0 would race to the last page.
        try await Task.sleep(for: .seconds(min(max(seconds, 2), 20)))
        while model.advance(by: 1) == .blocked {
            // Blocked while the comic opens, or with this page's panels unknown (detection still running),
            // retries shortly; blocked otherwise is the end of the book or a comic that failed to open.
            let waiting = model.state == .loading
                || (model.state == .ready && model.mode == .panels && model.slots.regions == nil)
            guard waiting else { playing = false; return }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { model.advance(by: -1) } label: { Label("Previous panel", systemImage: "chevron.left") }
                .help("Previous panel (Left Arrow)")
            Button { model.advance(by: 1) } label: { Label("Next panel", systemImage: "chevron.right") }
                .help("Next panel (Right Arrow)")
            Button { playing.toggle() } label: {
                Label(playing ? "Pause auto-advance" : "Auto-advance", systemImage: playing ? "pause.fill" : "play.fill")
            }
                .help(playing ? "Pause auto-advance (P)" : "Auto-advance: next panel every \(seconds) s (P)")
            // Label hidden: at the 240 pt minimum width it truncates and squeezes the opacity slider.
            Stepper(value: $seconds, in: 2...20) { Text("\(seconds) s") }
                .labelsHidden()
                .help("Seconds per panel when auto-advancing: \(seconds) s")
                .accessibilityLabel("Seconds per panel")
                .accessibilityValue("\(seconds) seconds")
            Slider(value: $opacity, in: 0.4...1)
                .tint(Chika.ochre)
                .frame(maxWidth: 110)
                .help("Window opacity")
                .accessibilityLabel("Window opacity")
            Spacer(minLength: 0)
            Button { window?.miniaturize(nil) } label: { Label("Minimize", systemImage: "minus") }
                .help("Minimize")
            Button {
                openWindow(id: "reader", value: model.comicURL)
                dismissWindow(id: "peek", value: model.comicURL)
            } label: { Label("Open full reader", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("Back to the full reader")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(Chika.cream)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(LinearGradient(colors: [.clear, Chika.ink.opacity(0.9)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

/// Reaches the peek's NSWindow: follows you across Spaces and over full-screen apps, stays up when
/// Chika is in the background, drags by its content, keeps the current panel's aspect while
/// resizing, and fades with the opacity slider.
private struct PeekWindowConfigurator: NSViewRepresentable {
    let aspect: CGSize
    let opacity: Double
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The view joins its window after this first update, so look it up on the next turn.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if self.window !== window {   // set once
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.hidesOnDeactivate = false
                window.isMovableByWindowBackground = true
                window.titlebarAppearsTransparent = true
                self.window = window
            }
            if window.aspectRatio != aspect {
                // A new panel shape: resize to it, keeping the current width.
                window.aspectRatio = aspect
                let w = window.frame.width
                window.setContentSize(CGSize(width: w, height: w * aspect.height / aspect.width))
            }
            window.alphaValue = opacity
        }
    }
}
