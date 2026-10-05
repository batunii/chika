#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Desktop library: bounded covers, a compact empty state, and reading in the same window.
struct MacLibraryView: View {
    @EnvironmentObject private var settings: ChikaSettings
    @StateObject private var library = LibraryStore()
    @State private var path: [URL] = []
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var pendingDelete: URL?
    @State private var progress: [String: Progress] = [:]
    @State private var defaultRTL = ReadingPrefs.defaultRightToLeft

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 24)]

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationBarHidden(true)
            .navigationDestination(for: URL.self) { url in
                ReaderView(comicURL: url)
                    .environmentObject(settings)
                    .onDisappear { library.refresh(); reloadProgress() }
            }
        }
        .background(MacWindowLayout().frame(width: 0, height: 0))
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
        .sheet(isPresented: $showSettings) {
            MenuView().environmentObject(settings)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 540, idealHeight: 620)
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
        .onAppear { library.refresh(); reloadProgress() }
        .onOpenURL { url in library.importComic(from: url) }
    }

    private var header: some View {
        HStack(spacing: 18) {
            ChikaMark(size: 42)
            ChikaWordmark()
            Spacer(minLength: 16)
            Menu {
                Button { setDirection(false) } label: {
                    if defaultRTL { Text("Left to right") }
                    else { Label("Left to right", systemImage: "checkmark") }
                }
                Button { setDirection(true) } label: {
                    if defaultRTL { Label("Right to left", systemImage: "checkmark") }
                    else { Text("Right to left") }
                }
            } label: {
                Label(defaultRTL ? "Right to left" : "Left to right", systemImage: "arrow.left.arrow.right")
                    .font(.archivo(13)).foregroundColor(Chika.cream)
            }
            .help("Reading direction for new comics")
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Chika.cream)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Settings")
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)
            importButton
                .keyboardShortcut("o", modifiers: .command)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
    }

    private var importButton: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 8) {
                if library.importing {
                    ProgressView().tint(Chika.cream)
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
            Text("⌘O to import comics")
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
                        NavigationLink(value: url) {
                            ComicCard(url: url, progress: progress[url.lastPathComponent])
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { pendingDelete = url } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func setDirection(_ rtl: Bool) {
        defaultRTL = rtl
        ReadingPrefs.defaultRightToLeft = rtl
    }

    private func reloadProgress() {
        progress = Dictionary(uniqueKeysWithValues: library.comics.compactMap { url in
            ReadingProgress.get(url).map { (url.lastPathComponent, $0) }
        })
    }
}

/// Give the desktop a useful initial size once, while preserving macOS window restoration later.
private struct MacWindowLayout: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { WindowView() }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class WindowView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 760, height: 520)
            let key = "chika.macWindowLayout.v1"
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            var frame = scene.effectiveGeometry.systemFrame
            frame.size = CGSize(width: 1000, height: 740)
            scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.Mac(systemFrame: frame))
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}
#endif
