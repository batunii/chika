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
        case ready(CbzArchive)
    }

    private static let detector = CoreMLPanelDetector()

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var page = 0
    @State private var pageCount = 1
    @State private var image: UIImage?
    @State private var regions: [Panel] = [Panel.companion.FULL_PAGE]
    @State private var step = -1
    @State private var detecting = false
    @State private var rightToLeft = false
    @State private var showChrome = true

    private var title: String { comicURL.deletingPathExtension().lastPathComponent.uppercased() }
    private var camera: Panel {
        (step >= 0 && step < regions.count) ? regions[step] : Panel.companion.FULL_PAGE
    }

    var body: some View {
        ZStack {
            Chika.ink.ignoresSafeArea()
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
            case .ready(let archive):
                readerBody(archive)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showChrome)
        .task { load() }
    }

    private func load() {
        do {
            let archive = try CbzArchive(url: comicURL)
            guard archive.pageCount > 0 else { state = .failed("No image pages found in this archive"); return }
            pageCount = Int(archive.pageCount)
            // Resume where we left off (page and panel), clamped to the current page count.
            if let saved = ReadingProgress.get(comicURL) {
                page = min(max(saved.page, 0), pageCount - 1)
            }
            state = .ready(archive)
            loadPage(archive, restoreStep: ReadingProgress.get(comicURL)?.step ?? -1)
        } catch {
            state = .failed("Could not open archive: \(error.localizedDescription)")
        }
    }

    private func loadPage(_ archive: CbzArchive, restoreStep: Int = -1) {
        step = restoreStep
        regions = [Panel.companion.FULL_PAGE]
        image = (try? archive.readPage(page)).flatMap(UIImage.init(data:))
        persist()
        redetect()
    }

    private func persist() {
        ReadingProgress.set(comicURL, page: page, step: step, total: pageCount)
    }

    private func redetect() {
        guard let img = image, let detector = Self.detector else { return }
        let rtl = rightToLeft
        let forPage = page
        detecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = detector.zoomRegions(for: img, rightToLeft: rtl)
            DispatchQueue.main.async {
                guard forPage == page else { return }
                regions = found
                if step >= found.count { step = found.count - 1 } // keep a restored panel in range
                detecting = false
            }
        }
    }

    @ViewBuilder
    private func readerBody(_ archive: CbzArchive) -> some View {
        GeometryReader { geo in
            ZStack {
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
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: page)
                } else {
                    ProgressView().tint(Chika.ochre)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay { if showChrome { Reticle(color: Chika.cream, inset: 6) } }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    let x = value.location.x
                    if x > geo.size.width * 0.66 { advance(by: 1, in: archive) }
                    else if x < geo.size.width * 0.33 { advance(by: -1, in: archive) }
                    else { withAnimation { showChrome.toggle() } }
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
                    KickerText(detecting ? "Detecting…" : "Reading", size: 8)
                }
            }
            Spacer()
            Button(rightToLeft ? "RTL" : "LTR") { rightToLeft.toggle(); redetect() }
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
            PageCoin(page: page + 1, total: pageCount)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    /// Steps through panels, rolling over to the next/previous page at the ends.
    private func advance(by delta: Int, in archive: CbzArchive) {
        let next = step + delta
        if next >= regions.count {
            guard page + 1 < Int(archive.pageCount) else { return }
            page += 1; loadPage(archive)
        } else if next < -1 {
            guard page > 0 else { return }
            page -= 1; loadPage(archive)
        } else {
            step = next
            persist()
        }
    }
}
