import SwiftUI
import ChikaCore

/// The Chika library: pulp-comic identity matching the Android design (ink ground with a halftone
/// wash, the three-panel mark + CHI·KA wordmark) over a grid of comic cards. Each comic opens in its
/// own reader window.
struct LibraryView: View {
    @EnvironmentObject private var settings: ChikaSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
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
    @State private var opened: [String: Double] = [:]
    @State private var query = ""
    @AppStorage("chika.library.sort") private var sort = LibraryStore.Sort.recent
    @AppStorage("chika.library.unreadOnly") private var unreadOnly = false

    // Top-aligned so covers line up when titles and issue lines differ in height.
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 24, alignment: .top)]

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
                    if let url { Task { @MainActor in library.add(url) } }
                }
            }
            return true
        }
        // One importer for both modes: SwiftUI only honours one .fileImporter per view.
        .fileImporter(
            isPresented: $showPicker,
            // Folders in both: a folder of images imports as one comic.
            allowedContentTypes: LibraryStore.importableTypes + [.folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls { if pickMode == .inPlace { library.addInPlace(url) } else { library.importComic(from: url) } }
            case .failure(let error): library.report(error.localizedDescription)
            }
        }
        // Not only imports: removals, an already-added folder and failed progress saves are said here too.
        .alert("Library", isPresented: Binding(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importError ?? "")
        }
        .alert(pendingDelete.map { "\(removalLabel($0))?" } ?? "", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button(pendingDelete.map(removalLabel) ?? "Remove", role: .destructive) {
                if let url = pendingDelete { library.delete(url) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map(removalMessage) ?? "")
        }
        .onAppear {
            progress = ReadingProgress.all()
            opened = ReadingProgress.openedMap()
            ShortcutTarget.library = library
            ShortcutTarget.windows = (openWindow, dismissWindow)
            for url in library.takeComicsToReopen() { openWindow(id: "reader", value: url) }
        }
        // Reader windows save progress and recency on every step; keep cards and order live.
        .onReceive(NotificationCenter.default.publisher(for: ReadingProgress.didChange)) { _ in
            progress = ReadingProgress.all()
            opened = ReadingProgress.openedMap()
        }
        .onOpenURL { url in library.open(fromFinder: url) { openWindow(id: "reader", value: $0) } }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])   // see ChikaApp
    }

    private var libraryControls: some View {
        HStack(spacing: 10) {
            TextField("Search title, series, writer", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Picker("Sort", selection: $sort) {
                ForEach(LibraryStore.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Toggle("Unread only", isOn: $unreadOnly)
                .toggleStyle(.button)
                .fixedSize()
                .help("Hide comics read to the last page")
        }
        .font(.archivo(13))
    }

    private func removalLabel(_ url: URL) -> String {
        if let source = library.sources[url] { return source == url ? "Remove from Library" : "Stop Watching “\(source.lastPathComponent)”" }
        return library.isImportedCopy(url) ? "Delete Imported Copy" : "Remove"
    }

    private func removalMessage(_ url: URL) -> String {
        if let source = library.sources[url] {
            return source == url
                ? "The comic leaves the library. The file itself is untouched."
                : "Every comic in “\(source.lastPathComponent)” leaves the library. The files themselves are untouched."
        }
        return library.isImportedCopy(url)
            ? "Chika's copy of “\(url.comicTitle)” is deleted for good, with its reading progress, bookmarks and panel edits. The file you imported it from is untouched."
            : "The comic leaves the library."
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
            Text("Import a CBZ, CBR, CB7 or PDF comic, or a folder of images, to begin reading.")
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
                let groups = LibraryStore.arrange(library.comics, query: query, sort: sort, unreadOnly: unreadOnly,
                                                  keys: library.keys, progress: progress, opened: opened, info: library.info)
                let shown = groups.reduce(0) { $0 + $1.comics.count }
                let resume = query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? LibraryStore.continueReading(library.comics, keys: library.keys, progress: progress, opened: opened) : []
                if !resume.isEmpty {
                    KickerText("Continue Reading", size: 13, color: Chika.ochre)
                    ScrollView(.horizontal, showsIndicators: false) {
                        // Not lazy: a lazy row sizes its height before every card is measured, clipping
                        // a card whose title wraps to two lines.
                        HStack(alignment: .top, spacing: 24) {
                            // The 20 most recent: being eager, the row loads every card's cover at once.
                            ForEach(resume.prefix(20), id: \.self) { url in card(url).frame(width: 150) }
                        }
                        .padding(.bottom, 8)   // room for the cards' hard shadow
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Continue reading")
                }
                HStack(spacing: 14) {
                    KickerText("Your Library", size: 13, color: Chika.ochre)
                    Text(shown == library.comics.count
                         ? "\(shown) \(shown == 1 ? "comic" : "comics")"
                         : "\(shown) of \(library.comics.count)")
                        .font(.archivo(13)).foregroundColor(Chika.creamMuted)
                    Spacer()
                    libraryControls
                }
                if shown == 0 {
                    Text("No comics match.").font(.archivo(14)).foregroundColor(Chika.creamMuted).padding(.vertical, 24)
                }
                ForEach(groups, id: \.series) { group in
                    // Section titles only once there is a series to tell apart.
                    if groups.count > 1 || group.series != nil {
                        Text((group.series ?? "Other comics").uppercased())
                            .font(.anton(18)).foregroundColor(Chika.cream).padding(.top, 8)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        ForEach(group.comics, id: \.self) { url in card(url) }
                        if group.series == groups.last?.series {
                            AddTile(importing: library.importing) { pickMode = .importCopies; showPicker = true }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func card(_ url: URL) -> some View {
        Button { openWindow(id: "reader", value: url) } label: {
            ComicCard(url: url, progress: library.keys[url].flatMap { progress[$0] }, info: library.info[url],
                      revision: library.revisions[url])
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { openWindow(id: "reader", value: url) }
            if let folder = library.sources[url], folder != url {
                // Removing acts on the whole watched folder, not this comic: the menu says so.
                Section("Watched folder “\(folder.lastPathComponent)”") {
                    Button(role: .destructive) { pendingDelete = url } label: {
                        Label("Stop Watching Folder", systemImage: "eye.slash")
                    }
                }
            } else {
                Button(role: .destructive) { pendingDelete = url } label: {
                    Label(removalLabel(url), systemImage: library.isImportedCopy(url) ? "trash" : "minus.circle")
                }
            }
        }
    }
}

/// A single comic in the grid, matching Android: a 0.7-aspect cover under a hard comic shadow with
/// a full-width progress bar along its bottom edge, the title in Archivo below the cover, and a
/// progress/page-count line. A strict port of Android's ComicCard.
struct ComicCard: View {
    let url: URL
    let progress: Progress?
    var info: ComicInfo?
    /// The file's ReadingProgress revision: a comic still being copied in loads its cover again once complete.
    var revision: String?
    @State private var cover: NSImage?
    @State private var pages = 0

    private var title: String { url.comicTitle.uppercased() }
    private var lastPage: Int { progress?.page ?? 0 }
    private var pageCount: Int { progress?.total ?? pages }
    private var started: Bool { lastPage > 0 }
    // "Vol. 2 · #3 · Writer" from ComicInfo.xml, when it has any of them.
    private var issueLine: String? {
        let parts = [info?.volume.map { "Vol. \($0)" }, info?.number.map { "#\($0)" }, info?.writer].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
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
            if let issue = issueLine {
                Text(issue)
                    .font(.archivo(12)).foregroundColor(Chika.ochre).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
            Text(started
                 ? "\(Int(pct * 100))% · pg \(lastPage + 1)/\(pageCount)"
                 : "\(pageCount) pages")
                .font(.archivo(12)).foregroundColor(Chika.creamMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .task(id: revision) {
            let loaded = await CoverLoader.load(for: url)
            guard !Task.isCancelled else { return }   // scrolled away, or replaced by a newer revision's load
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
