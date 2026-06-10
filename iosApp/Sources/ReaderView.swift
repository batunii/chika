import SwiftUI
import ChikaShared

/// Panel-by-panel CBZ reader: tapping the right side steps into each detected panel in reading
/// order (page → panel 1 → … → panel N → next page), tapping the left side steps back. Panels come
/// from the on-device Core ML detector via the shared Kotlin decoder + planner, and the camera is
/// framed by the shared computePageDraw — the same logic as the Android reader.
struct ReaderView: View {
    let comicURL: URL

    private enum LoadState {
        case loading
        case failed(String)
        case ready(CbzArchive)
    }

    private static let detector = CoreMLPanelDetector()

    @State private var state: LoadState = .loading
    @State private var page = 0
    @State private var image: UIImage?
    @State private var regions: [Panel] = [Panel.companion.FULL_PAGE]
    @State private var step = -1          // -1 = whole page, 0..<n = zoom region index
    @State private var detecting = false
    @State private var rightToLeft = false
    @State private var showChrome = true

    private var camera: Panel {
        (step >= 0 && step < regions.count) ? regions[step] : Panel.companion.FULL_PAGE
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch state {
            case .loading:
                ProgressView().tint(.white)
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message).multilineTextAlignment(.center)
                }
                .foregroundColor(.white)
                .padding()
            case .ready(let archive):
                readerBody(archive)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showChrome ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(rightToLeft ? "RTL" : "LTR") { rightToLeft.toggle(); redetect() }
                    .font(.caption.bold())
            }
        }
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
        step = -1
        regions = [Panel.companion.FULL_PAGE]
        image = (try? archive.readPage(Int32(page))).flatMap(UIImage.init(data:))
        redetect()
    }

    /// Runs detection off the main thread; the page stays readable (whole-page) while it works.
    private func redetect() {
        guard let img = image, let detector = Self.detector else { return }
        let rtl = rightToLeft
        let forPage = page
        detecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = detector.zoomRegions(for: img, rightToLeft: rtl)
            DispatchQueue.main.async {
                guard forPage == page else { return } // user already moved on
                regions = found
                detecting = false
            }
        }
    }

    @ViewBuilder
    private func readerBody(_ archive: CbzArchive) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image {
                    let draw = CameraTransformKt.computePageDraw(
                        camera: camera,
                        bitmapW: Int32(image.cgImage?.width ?? 1),
                        bitmapH: Int32(image.cgImage?.height ?? 1),
                        containerW: Float(geo.size.width),
                        containerH: Float(geo.size.height),
                        fill: 0.98
                    )
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: CGFloat(draw.scaledWidth), height: CGFloat(draw.scaledHeight))
                        .offset(x: CGFloat(draw.left), y: CGFloat(draw.top))
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: page)
                } else {
                    ProgressView().tint(.white).frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    let x = value.location.x
                    if x > geo.size.width * 0.66 {
                        advance(by: 1, in: archive)
                    } else if x < geo.size.width * 0.33 {
                        advance(by: -1, in: archive)
                    } else {
                        withAnimation { showChrome.toggle() }
                    }
                }
            )
        }
        .overlay(alignment: .top) {
            if detecting && showChrome {
                Text("Detecting panels…")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if showChrome { chrome(archive) }
        }
    }

    private func chrome(_ archive: CbzArchive) -> some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { Double(page) },
                    set: { page = Int($0.rounded()); loadPage(archive) }
                ),
                in: 0...Double(max(archive.pageCount - 1, 1)),
                step: 1
            )
            Text(step < 0
                 ? "Page \(page + 1) of \(archive.pageCount) — tap right to step into panels"
                 : "Panel \(step + 1) of \(regions.count) · page \(page + 1)/\(archive.pageCount)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))
        }
        .padding()
        .background(.black.opacity(0.6))
    }

    /// Steps through panels, rolling over to the next/previous page at the ends — the page→panel→
    /// next-page flow from the Android reader.
    private func advance(by delta: Int, in archive: CbzArchive) {
        let next = step + delta
        if next >= regions.count {
            guard page + 1 < archive.pageCount else { return }
            page += 1
            loadPage(archive)
        } else if next < -1 {
            guard page > 0 else { return }
            page -= 1
            loadPage(archive)
        } else {
            step = next
        }
    }
}
