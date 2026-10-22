import SwiftUI

/// The Chika library: pulp-comic identity matching the Android design (ink ground with a halftone
/// wash, the three-panel mark + CHI·KA wordmark) over a grid of comic cards. Each comic opens in its
/// own reader window.
struct LibraryView: View {
    @EnvironmentObject private var settings: ChikaSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var library: LibraryStore
    @State private var showPicker = false
    // What the picker does: import copies, or add files/folders in place. Kept apart from
    // showPicker because the importer clears that before its completion runs.
    @State private var pickMode = PickMode.importCopies
    private enum PickMode { case importCopies, inPlace }
    // Comic awaiting delete confirmation (Android shows a "Remove comic?" dialog before deleting).
    @State private var pendingDelete: URL?
    // Resume snapshot keyed by ReadingProgress.key, so cards show fresh progress without resetting scroll.
    @State private var progress: [String: Progress] = [:]

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 24)]

    var body: some View {
        ZStack {
            settings.ground.ignoresSafeArea()
            Halftone(color: Chika.crimson, alpha: 0.035).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Rectangle().fill(Chika.cream.opacity(0.12)).frame(height: 1)
                if library.comics.isEmpty {
                    emptyLibrary
                } else {
                    comicGrid
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    // A dropped folder is watched in place; dropped files are imported as copies.
                    let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    Task { @MainActor in if isFolder { library.addInPlace(url) } else { library.importComic(from: url) } }
                }
            }
            return true
        }
        // One importer for both modes: SwiftUI only honours one .fileImporter per view.
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: LibraryStore.importableTypes + (pickMode == .inPlace ? [.folder] : []),
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls { if pickMode == .inPlace { library.addInPlace(url) } else { library.importComic(from: url) } }
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
            Button("Remove", role: .destructive) {
                if let url = pendingDelete { library.delete(url) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map(removalMessage) ?? "")
        }
        .onAppear { progress = ReadingProgress.all() }
        // Reader windows save progress and recency on every step; keep cards and order live.
        .onReceive(NotificationCenter.default.publisher(for: ReadingProgress.didChange)) { _ in
            library.refresh()
            progress = ReadingProgress.all()
        }
        .onOpenURL { url in library.importComic(from: url) }
    }

    private func removalLabel(_ url: URL) -> String {
        guard let source = library.sources[url] else { return "Remove" }
        return source == url ? "Remove from Library" : "Stop Watching “\(source.lastPathComponent)”"
    }

    private func removalMessage(_ url: URL) -> String {
        guard let source = library.sources[url] else { return "This deletes the imported copy. The original file is untouched." }
        return source == url
            ? "The comic leaves the library. The file itself is untouched."
            : "Every comic in “\(source.lastPathComponent)” leaves the library. The files themselves are untouched."
    }

    private var header: some View {
        HStack(spacing: 18) {
            ChikaMark(size: 42)
            ChikaWordmark()
            Spacer(minLength: 16)
            Menu {
                Picker("Reading direction", selection: $settings.defaultRightToLeft) {
                    Text("Left to right").tag(false)
                    Text("Right to left").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Label(settings.defaultRightToLeft ? "Right to left" : "Left to right", systemImage: "arrow.left.arrow.right")
                    .font(.archivo(13)).foregroundColor(Chika.cream)
            }
            .fixedSize()
            .help("Reading direction for new comics")
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Chika.cream)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Settings")
            .help("Settings")
            Button { pickMode = .inPlace; showPicker = true } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Chika.cream)
                    .frame(width: 36, height: 36)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .accessibilityLabel("Add comics or folders in place")
            .help("Read comics or watch folders where they are, without copying (⇧⌘O)")
            importButton
                .keyboardShortcut("o", modifiers: .command)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
    }

    private var importButton: some View {
        Button { pickMode = .importCopies; showPicker = true } label: {
            HStack(spacing: 8) {
                if library.importing {
                    ProgressView().controlSize(.small).tint(Chika.cream)
                } else {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                }
                Text(library.importing ? "Importing…" : "Import comics")
                    .font(.archivo(14, weight: 700))
            }
            .foregroundColor(Chika.cream)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Chika.crimson)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(library.importing)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            ChikaMark(size: 72)
                .padding(.bottom, 8)
            Text("YOUR LIBRARY STARTS HERE")
                .font(.anton(30)).foregroundColor(Chika.cream)
            Text("Import a CBZ, CBR, ZIP, or RAR comic to begin reading.")
                .font(.archivo(15)).foregroundColor(Chika.creamMuted)
            importButton.padding(.top, 4)
            Text("⌘O to import copies, ⇧⌘O to read files or folders in place, or drop them here")
                .font(.archivo(12)).foregroundColor(Chika.creamMuted)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comicGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    KickerText("Your Library", size: 13, color: Chika.ochre)
                    Spacer()
                    Text("\(library.comics.count) \(library.comics.count == 1 ? "comic" : "comics")")
                        .font(.archivo(13)).foregroundColor(Chika.creamMuted)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(library.comics, id: \.self) { url in
                        Button { openWindow(id: "reader", value: url) } label: {
                            ComicCard(url: url, progress: progress[ReadingProgress.key(url)])
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { pendingDelete = url } label: {
                                Label(removalLabel(url), systemImage: "trash")
                            }
                        }
                    }
                    AddTile(importing: library.importing) { pickMode = .importCopies; showPicker = true }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// A single comic in the grid, matching Android: a 0.7-aspect cover under a hard comic shadow with
/// a full-width progress bar along its bottom edge, the title in Archivo below the cover, and a
/// progress/page-count line. A strict port of Android's ComicCard.
struct ComicCard: View {
    let url: URL
    let progress: Progress?
    @State private var cover: NSImage?
    @State private var pages = 0

    private var title: String { url.deletingPathExtension().lastPathComponent.uppercased() }
    private var lastPage: Int { progress?.page ?? 0 }
    private var pageCount: Int { progress?.total ?? pages }
    private var started: Bool { lastPage > 0 }
    // Android's fill formula: (lastPage + 1) / pageCount; page 0 already counts as "on page 1".
    private var pct: Double { pageCount > 0 ? min(max(Double(lastPage + 1) / Double(pageCount), 0), 1) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                Group {
                    if let cover {
                        Image(nsImage: cover).resizable().scaledToFill()
                    } else {
                        GeneratedCover(title: title)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                // Progress bar inside the cover's bottom edge, always shown (0% when unstarted).
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
                .font(.archivo(15, weight: 800)).foregroundColor(Chika.cream)
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 9)
            Text(started
                 ? "\(Int(pct * 100))% · pg \(lastPage + 1)/\(pageCount)"
                 : "\(pageCount) pages")
                .font(.archivo(12)).foregroundColor(Chika.creamMuted)
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
/// and the title in Anton bottom-left (Android's GeneratedCover).
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
/// starburst holding a + (or a spinner while importing), Android's AddTile.
struct AddTile: View {
    let importing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                ZStack {
                    StarburstShape().fill(Chika.crimson).frame(width: 64, height: 64)
                    if importing {
                        ProgressView().controlSize(.small).tint(Chika.cream)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
