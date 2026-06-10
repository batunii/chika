import SwiftUI
import ChikaShared

/// Whole-page CBZ reader: tap right/left to turn pages, pinch to zoom, drag to pan, slider to
/// scrub. Panel-by-panel stepping arrives once ML detection lands on iOS — the interaction shell
/// already mirrors the Android reader's tap zones.
struct ReaderView: View {
    let comicURL: URL

    private enum LoadState {
        case loading
        case failed(String)
        case ready(CbzArchive)
    }

    @State private var state: LoadState = .loading
    @State private var page = 0
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    @State private var showChrome = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch state {
            case .loading:
                ProgressView().tint(.white)
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message)
                }
                .foregroundColor(.white)
                .padding()
            case .ready(let archive):
                readerBody(archive)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showChrome ? .visible : .hidden, for: .navigationBar)
        .statusBarHidden(!showChrome)
        .task { load() }
    }

    private func load() {
        do {
            let archive = try CbzArchive(url: comicURL)
            guard archive.pageCount > 0 else {
                state = .failed("No image pages found in this archive")
                return
            }
            state = .ready(archive)
            loadPage(archive)
        } catch {
            state = .failed("Could not open archive: \(error.localizedDescription)")
        }
    }

    private func loadPage(_ archive: CbzArchive) {
        image = (try? archive.readPage(page)).flatMap(UIImage.init(data:))
        scale = 1; steadyScale = 1
        offset = .zero; steadyOffset = .zero
    }

    @ViewBuilder
    private func readerBody(_ archive: CbzArchive) -> some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .contentShape(Rectangle())
            .gesture(zoomAndPan)
            .gesture(
                SpatialTapGesture().onEnded { value in
                    if scale > 1.01 { return } // zoomed in: taps reserved for future panel steps
                    let x = value.location.x
                    if x > geo.size.width * 0.66 {
                        turnPage(by: 1, in: archive)
                    } else if x < geo.size.width * 0.33 {
                        turnPage(by: -1, in: archive)
                    } else {
                        withAnimation { showChrome.toggle() }
                    }
                }
            )
            .gesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.spring(response: 0.35)) {
                        scale = scale > 1.01 ? 1 : 2.2
                        steadyScale = scale
                        offset = .zero; steadyOffset = .zero
                    }
                }
            )
        }
        .overlay(alignment: .bottom) {
            if showChrome {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { Double(page) },
                            set: { page = Int($0.rounded()); loadPage(archive) }
                        ),
                        in: 0...Double(archive.pageCount - 1),
                        step: 1
                    )
                    Text("Page \(page + 1) of \(archive.pageCount)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
                .background(.black.opacity(0.6))
            }
        }
    }

    private var zoomAndPan: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    scale = max(1, min(steadyScale * value, 6))
                }
                .onEnded { _ in
                    steadyScale = scale
                    if scale <= 1.01 { offset = .zero; steadyOffset = .zero }
                },
            DragGesture()
                .onChanged { value in
                    guard scale > 1.01 else { return }
                    offset = CGSize(
                        width: steadyOffset.width + value.translation.width,
                        height: steadyOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in steadyOffset = offset }
        )
    }

    private func turnPage(by delta: Int, in archive: CbzArchive) {
        let next = page + delta
        guard next >= 0 && next < archive.pageCount else { return }
        page = next
        loadPage(archive)
    }
}
