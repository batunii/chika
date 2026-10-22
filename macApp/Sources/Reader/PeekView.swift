import SwiftUI
import AppKit
import ChikaCore

/// Floating "peek" window: only the current panel of the comic's shared ReaderModel, no chrome, so
/// you can keep reading in a small always-on-top window while working in another app. A bar fades
/// in on hover with panel steps, window opacity, minimize, and expand back to the full reader.
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
    @State private var window: NSWindow?
    @FocusState private var focused: Bool

    // The current camera's size in bitmap pixels: its ratio is the window's aspect.
    private var aspect: CGSize {
        guard let cg = model.image else { return CGSize(width: 1, height: 1) }
        let camera = model.slots.camera
        return CGSize(width: CGFloat(camera.width) * CGFloat(cg.width),
                      height: max(CGFloat(camera.height) * CGFloat(cg.height), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let camera = model.slots.camera
            ZStack(alignment: .topLeading) {
                if let cg = model.image {
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
        .onKeyPress(.leftArrow) { model.advance(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.advance(by: 1); return .handled }
        .onKeyPress(.space, phases: .down) { press in
            model.advance(by: press.modifiers.contains(.shift) ? -1 : 1); return .handled
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { model.advance(by: -1) } label: { Label("Previous panel", systemImage: "chevron.left") }
                .help("Previous panel (Left Arrow)")
            Button { model.advance(by: 1) } label: { Label("Next panel", systemImage: "chevron.right") }
                .help("Next panel (Right Arrow)")
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
