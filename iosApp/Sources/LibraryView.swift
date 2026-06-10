import SwiftUI

/// The Chika library — pulp-comic identity matching the Android design: ink ground with a halftone
/// wash, the three-panel mark + CHI·KA wordmark, an ochre "YOUR LIBRARY" badge, and a two-column
/// grid of comic cards with issue tags and Anton titles.
struct LibraryView: View {
    @StateObject private var library = LibraryStore()
    @State private var showPicker = false
    // Resume snapshot keyed by filename, refreshed on appear and when returning from the reader so
    // cards show fresh progress without resetting scroll position.
    @State private var progress: [String: Progress] = [:]

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                Chika.ink.ignoresSafeArea()
                Halftone(color: Chika.cream, alpha: 0.05).ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    if library.comics.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                }

                if library.importing {
                    VStack(spacing: 10) {
                        ProgressView().tint(Chika.ochre)
                        KickerText("Converting CBR…")
                    }
                    .padding(24)
                    .background(Chika.inkSoft.opacity(0.95))
                    .clipShape(RoundedCornerShape(cornerRadius: 6))
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: URL.self) { url in
                ReaderView(comicURL: url).onDisappear { reloadProgress() }
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
            .onAppear(perform: reloadProgress)
        }
    }

    private func reloadProgress() {
        var map: [String: Progress] = [:]
        for url in library.comics { map[url.lastPathComponent] = ReadingProgress.get(url) }
        progress = map
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ChikaMark(size: 40)
                ChikaWordmark()
                Spacer()
                Button { showPicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Chika.ink)
                        .frame(width: 38, height: 38)
                        .background(Chika.ochre)
                        .clipShape(RoundedCornerShape(cornerRadius: 3))
                        .comicShadow(offset: 3, color: .black.opacity(0.6), corner: 3)
                }
            }
            OchreBadge(text: "Your Library")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(library.comics, id: \.self) { url in
                    NavigationLink(value: url) {
                        ComicCard(url: url, issue: issueNumber(url), progress: progress[url.lastPathComponent] ?? nil)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { library.delete(url) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ChikaMark(size: 72)
            Text("NO COMICS YET").font(.anton(22)).foregroundColor(Chika.cream)
            KickerText("Tap + to import a CBZ/CBR from Files")
            // Diagnostic: shows what the app actually sees on disk, so an import-vs-render issue is
            // visible. Tap the storage line to re-scan.
            Text(library.storageReport)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Chika.creamMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .onTapGesture { library.refresh() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Best-effort issue label from the filename (e.g. "...01" → "01"), else a stable index.
    private func issueNumber(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let digits = name.suffix(while: { $0.isNumber })
        if !digits.isEmpty { return String(digits.suffix(2)) }
        let idx = (library.comics.firstIndex(of: url) ?? 0) + 1
        return String(format: "%02d", idx)
    }
}

/// A single comic in the grid: cover (or maroon halftone placeholder) under a hard comic shadow,
/// an ISSUE tag top-left, and the title in Anton across the bottom — the Android card styling.
struct ComicCard: View {
    let url: URL
    let issue: String
    let progress: Progress?
    @State private var cover: UIImage?

    private var title: String { url.deletingPathExtension().lastPathComponent.uppercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Chika.maroon
                            Halftone(color: Chika.ink, alpha: 0.18)
                        }
                    }
                }
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()

                LinearGradient(colors: [.clear, Chika.ink.opacity(0.85)], startPoint: .center, endPoint: .bottom)

                Text(title)
                    .font(.anton(20)).foregroundColor(Chika.cream).lineLimit(2)
                    .padding(12)

                KickerText("Issue \(issue)", size: 8, color: Chika.creamMuted)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 220)
            .clipShape(RoundedCornerShape(cornerRadius: 4))
            .overlay(RoundedCornerShape(cornerRadius: 4).stroke(Chika.ink, lineWidth: 2))
            .comicShadow(offset: 4, color: .black.opacity(0.55), corner: 4)

            progressFooter
        }
    }

    @ViewBuilder
    private var progressFooter: some View {
        if let progress, progress.total > 0 {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Chika.inkSoft).frame(height: 3)
                        Capsule().fill(Chika.ochre)
                            .frame(width: max(3, geo.size.width * progress.fraction), height: 3)
                    }
                }
                .frame(height: 3)
                KickerText("\(progress.percent)% · pg \(progress.page + 1)/\(progress.total)", size: 7)
            }
            .padding(.horizontal, 2)
        } else {
            KickerText("Unread", size: 7).padding(.horizontal, 2)
        }
    }
}

/// RoundedRectangle alias matching Android's RoundedCornerShape naming, for readability.
struct RoundedCornerShape: Shape {
    var cornerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}

private extension StringProtocol {
    /// Trailing run of characters matching a predicate (e.g. trailing digits of a filename).
    func suffix(while predicate: (Character) -> Bool) -> String {
        String(reversed().prefix(while: predicate).reversed())
    }
}
