import SwiftUI

/// The Chika library — pulp-comic identity matching the Android design: ink ground with a halftone
/// wash, the three-panel mark + CHI·KA wordmark, an ochre "YOUR LIBRARY" badge, and a two-column
/// grid of comic cards with issue tags and Anton titles.
struct LibraryView: View {
    @EnvironmentObject private var settings: ChikaSettings
    @StateObject private var library = LibraryStore()
    @State private var showPicker = false
    @State private var showMenu = false
    // Comic awaiting delete confirmation (Android shows a "Remove comic?" dialog before deleting).
    @State private var pendingDelete: URL?
    // Resume snapshot keyed by filename, refreshed on appear and when returning from the reader so
    // cards show fresh progress without resetting scroll position.
    @State private var progress: [String: Progress] = [:]
    // Programmatic navigation, also driven by the QA auto-open hook below.
    @State private var path = NavigationPath()
    // Global default reading direction for comics not yet opened (the global half of the
    // per-comic + default behaviour). Mirrors ReadingPrefs so the pill redraws on toggle.
    @State private var defaultRTL = ReadingPrefs.defaultRightToLeft

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                settings.ground.ignoresSafeArea()
                Halftone(color: Chika.crimson, alpha: 0.05).ignoresSafeArea()
                // Decorative action-burst behind the header (Android LibraryScreen).
                StarburstShape().fill(Chika.crimson.opacity(0.14))
                    .frame(width: 180, height: 180)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 10)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    header
                    content
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: URL.self) { url in
                ReaderView(comicURL: url).onDisappear { reloadProgress() }
            }
            .fullScreenCover(isPresented: $showMenu) {
                MenuView().environmentObject(settings)
            }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: LibraryStore.importableTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): urls.forEach(library.importComic)
                case .failure(let error): library.importError = error.localizedDescription
                }
            }
            .alert("Import failed", isPresented: Binding(
                get: { library.importError != nil },
                set: { if !$0 { library.importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.importError ?? "")
            }
            .alert("Remove comic?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    if let url = pendingDelete { library.delete(url) }
                    pendingDelete = nil
                }
            } message: {
                Text("This removes the imported copy. The original file is untouched.")
            }
            // refresh() re-sorts by recency so a just-read comic jumps to the top (Android parity).
            .onAppear { library.refresh(); reloadProgress(); autoOpenIfDebug() }
        }
    }

    /// QA hook: when launched with the CHIKA_DEBUG_OPEN env var (an index or filename substring),
    /// push straight into that comic's reader. Never set in production, so this is a no-op there.
    private func autoOpenIfDebug() {
        guard path.isEmpty,
              let target = ProcessInfo.processInfo.environment["CHIKA_DEBUG_OPEN"],
              !library.comics.isEmpty else { return }
        let match = Int(target).flatMap { library.comics.indices.contains($0) ? library.comics[$0] : nil }
            ?? library.comics.first { $0.lastPathComponent.localizedCaseInsensitiveContains(target) }
            ?? library.comics.first
        if let match { path.append(match) }
    }

    private func reloadProgress() {
        var map: [String: Progress] = [:]
        for url in library.comics { map[url.lastPathComponent] = ReadingProgress.get(url) }
        progress = map
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ChikaWordmark()
                Spacer()
                Button { showMenu = true } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Chika.cream)
                        .frame(width: 36, height: 36)
                        .background(Chika.cream.opacity(0.10))
                        .clipShape(Circle())
                }
            }
            HStack(alignment: .center) {
                OchreBadge(text: "Your Library")
                Spacer()
                // Global default direction for new comics; each comic remembers its own once opened.
                Button {
                    defaultRTL.toggle()
                    ReadingPrefs.defaultRightToLeft = defaultRTL
                } label: {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("NEW COMICS OPEN").font(.archivo(7)).foregroundColor(Chika.creamMuted)
                        Text(defaultRTL ? "RTL" : "LTR")
                            .font(.archivo(12)).foregroundColor(Chika.ink)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Chika.ochre)
                            .clipShape(RoundedCornerShape(cornerRadius: 3))
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 6)
    }

    // Grid of comic cards followed by the "LOAD COMIC" tile, matching Android's single grid (the
    // empty-library line renders above the tile when there are no comics).
    private var content: some View {
        ScrollView {
            if library.comics.isEmpty {
                Text("No comics yet. Tap LOAD COMIC to add a CBZ or CBR.")
                    .font(.archivo(13)).foregroundColor(Chika.creamMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(library.comics, id: \.self) { url in
                    NavigationLink(value: url) {
                        ComicCard(url: url, progress: progress[url.lastPathComponent] ?? nil)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { pendingDelete = url } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                AddTile(importing: library.importing) { showPicker = true }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 48)
        }
    }
}

/// A single comic in the grid, matching Android: a 0.7-aspect cover under a hard comic shadow with
/// a full-width progress bar along its bottom edge, the title in Archivo below the cover, and a
/// progress/page-count line. The whole card is a strict port of Android's ComicCard.
struct ComicCard: View {
    let url: URL
    let progress: Progress?
    @State private var cover: UIImage?
    @State private var pages = 0

    private var title: String { url.deletingPathExtension().lastPathComponent.uppercased() }
    private var lastPage: Int { progress?.page ?? 0 }
    private var pageCount: Int { progress?.total ?? pages }
    private var started: Bool { lastPage > 0 }
    // Android's fill formula: (lastPage + 1) / pageCount — page 0 already counts as "on page 1".
    private var pct: Double { pageCount > 0 ? min(max(Double(lastPage + 1) / Double(pageCount), 0), 1) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        GeneratedCover(title: title)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                // Progress bar inside the cover's bottom edge — always shown (0% when unstarted).
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Chika.ink
                        Chika.ochre.frame(width: geo.size.width * CGFloat(pct))
                    }
                }
                .frame(height: 7)
            }
            .aspectRatio(0.7, contentMode: .fit)
            .background(Chika.inkSoft)
            .clipShape(RoundedCornerShape(cornerRadius: 4))
            .overlay(RoundedCornerShape(cornerRadius: 4).stroke(Chika.ink, lineWidth: 3))
            .comicShadow(offset: 5, color: .black.opacity(0.70), corner: 4)

            Text(title)
                .font(.archivo(12)).foregroundColor(Chika.cream)
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 9)
            Text(started
                 ? "\(Int(pct * 100))% · pg \(lastPage + 1)/\(pageCount)"
                 : "\(pageCount) pages")
                .font(.archivo(9.5)).foregroundColor(Chika.creamMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .task {
            let loaded = await CoverLoader.load(for: url)
            cover = loaded.cover
            pages = loaded.pageCount
        }
    }
}

/// Placeholder cover for comics with no extractable page-0 image: ink-soft ground, crimson halftone,
/// and the title in Anton bottom-left — Android's GeneratedCover.
struct GeneratedCover: View {
    let title: String
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Chika.inkSoft
            Halftone(color: Chika.crimson, alpha: 0.18)
            Text(title).font(.anton(22)).foregroundColor(Chika.cream).padding(12)
        }
    }
}

/// The in-grid "LOAD COMIC" tile: a dashed-border cell with an ochre halftone and a crimson
/// starburst holding a + (or a spinner while importing) — Android's AddTile.
struct AddTile: View {
    let importing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                ZStack {
                    StarburstShape().fill(Chika.crimson).frame(width: 64, height: 64)
                    if importing {
                        ProgressView().tint(Chika.cream)
                    } else {
                        Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundColor(Chika.cream)
                    }
                }
                Text("LOAD COMIC").font(.anton(14)).foregroundColor(Chika.cream)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(0.7, contentMode: .fit)
            .halftone(color: Chika.ochre, alpha: 0.10)
            .overlay(
                RoundedCornerShape(cornerRadius: 4)
                    .stroke(Chika.creamMuted, style: StrokeStyle(lineWidth: 3, dash: [14, 10]))
            )
            .clipShape(RoundedCornerShape(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

/// RoundedRectangle alias matching Android's RoundedCornerShape naming, for readability.
struct RoundedCornerShape: Shape {
    var cornerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}
