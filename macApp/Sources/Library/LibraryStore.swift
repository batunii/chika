import Foundation
import AppKit
import CoreServices
import UniformTypeIdentifiers
import ZIPFoundation
import ChikaCore

/// Comics come from two places. Imported copies live as plain .cbz files in the container's
/// Documents/Comics, the folder the Catalyst app used (same bundle id, same container), so an
/// existing library carries over. Every import, whatever its format, goes through one path: stage a
/// copy, convert CBR → CBZ, validate, then move in under a name that never overwrites. Comics read
/// in place (single files, or every comic under a watched folder) are reached through
/// security-scoped bookmarks and never copied or deleted. The list is a scan of both; per-comic
/// resume lives in ReadingProgress.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var comics: [URL] = []
    @Published var importing = false
    @Published var importError: String?
    /// Each comic's ReadingProgress key, read once per scan rather than on every render.
    @Published private(set) var keys: [URL: String] = [:]
    /// Each comic's ReadingProgress revision, so a card reloads its cover once a file being copied in is complete.
    @Published private(set) var revisions: [URL: String] = [:]
    /// ComicInfo.xml metadata of the comics that have it, filled in the background after a scan.
    @Published private(set) var info: [URL: ComicInfo] = [:]
    /// For comics read in place: the bookmarked file or watched folder each one came from.
    private(set) var sources: [URL: URL] = [:]
    private var infoRead: Set<URL> = []
    /// The latest metadata read, so tests can await it.
    private(set) var infoTask: Task<Void, Never>?

    private let dir: URL
    private let defaults: UserDefaults
    private var activeImports = 0
    private var roots: [(url: URL, bookmark: Data, isDirectory: Bool)] = []
    private var unresolved: [Data] = []
    private var stream: FSEventStreamRef?
    /// The scan FSEvents asked for, waiting for its burst to settle or running off the main thread.
    private var pendingScan: Task<Void, Never>?
    private static let bookmarksKey = "chika.bookmarks.v1"
    /// The comics with a reader window open, in the order they opened, saved on every change.
    private var openComics: [URL] = []
    /// Last session's open comics (ReadingProgress keys), until the first library window reopens them.
    private var toReopen: [String]
    /// Reopened at launch and not yet shown: their windows leave the comics' recency alone.
    private var reopening: Set<URL> = []
    /// False for the app hosting the unit tests, so they never reopen or rewrite the user's session.
    private let keepsSession: Bool
    private var quitting = false
    private var quitObserver: NSObjectProtocol?
    private var saveFailObserver: NSObjectProtocol?
    private static let openComicsKey = "chika.openComics.v1"
    // PDFs are left out of folder scans (a watched Downloads folder is full of them); add one directly.
    nonisolated static let inPlaceExtensions: Set = ["cbz", "cbr", "cb7"]

    /// Types the file importer allows. Includes the app's exported CBZ/CBR types plus the generic
    /// zip/archive/rar families so a plain .zip or .rar comic is selectable too.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.zip, .archive, .pdf]
        for id in ["com.chakra.comicreader.cbz", "com.chakra.comicreader.cbr", "com.chakra.comicreader.cb7",
                   "com.rarlab.rar-archive", "org.7-zip.7-zip-archive"] {
            if let type = UTType(id) { types.append(type) }
        }
        // macOS may associate these extensions with types declared by another installed reader.
        for ext in ["cbz", "cbr", "rar", "cb7", "7z"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// Whether this process is the host of the unit tests (it launches as the app, windows and all).
    static let hostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    /// `directory` overrides the library folder and `defaults` the bookmark store (tests pass their own).
    init(directory: URL? = nil, defaults: UserDefaults = .standard, keepsSession: Bool = true) {
        dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        self.defaults = defaults
        self.keepsSession = keepsSession
        toReopen = keepsSession ? defaults.stringArray(forKey: Self.openComicsKey) ?? [] : []
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ReadingProgress.migrateLegacy(in: dir)
        // shortcut: a bookmark that no longer resolves (file deleted, drive unplugged) is kept but
        // hidden, so a drive that comes back reappears; add a "missing" row if that confuses anyone.
        // Saved once every bookmark is back in the list: saving at the first stale one would drop the rest.
        var stale = false
        for data in defaults.array(forKey: Self.bookmarksKey) as? [Data] ?? [] { if resolve(data) { stale = true } }
        if stale { saveBookmarks() }
        watch()
        refresh()
        // Saved now, even empty: a comic gone since is never reopened later, nor one that takes its place.
        if keepsSession {
            let present = Set(keys.values)
            toReopen = toReopen.filter(present.contains)
            defaults.set(toReopen, forKey: Self.openComicsKey)
        }
        // Windows may disappear while quitting; those are the ones to reopen, so they stay saved.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitting = true }
        }
        saveFailObserver = NotificationCenter.default.addObserver(forName: ReadingProgress.saveDidFail, object: nil,
                                                                  queue: .main) { [weak self] note in
            let reason = note.object as? String ?? "unknown error"
            MainActor.assumeIsolated { self?.report("Couldn't save your reading progress (\(reason)). Check that the disk has free space.") }
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        if let saveFailObserver { NotificationCenter.default.removeObserver(saveFailObserver) }
    }

    /// Shows `message` in the library's alert, after any not dismissed yet (several files can fail at once).
    func report(_ message: String) {
        importError = importError.map { "\($0)\n\(message)" } ?? message
    }

    /// Rescans now, on the main thread: after the user adds or removes something, and at launch.
    func refresh() {
        pendingScan?.cancel()   // older than this scan
        followMovedRoots()
        apply(Self.snapshot(dir, roots))
    }

    /// FSEvents' rescan: waits for a burst of changes to settle, scans off the main thread, and drops a
    /// scan that a newer one (or `refresh()`) overtook. The task lets tests await it.
    @discardableResult
    func refreshSoon() -> Task<Void, Never> {
        pendingScan?.cancel()
        let task = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            followMovedRoots()
            let (dir, roots) = (dir, roots)
            let found = await Task.detached(priority: .utility) { Self.snapshot(dir, roots) }.value
            guard !Task.isCancelled else { return }
            let before = Set(comics)
            apply(found)
            markNew(comics.filter { !before.contains($0) })
        }
        pendingScan = task
        return task
    }

    private struct Snapshot {
        var comics: [URL], sources: [URL: URL], keys: [URL: String], revisions: [URL: String]
    }

    /// The library folder's comics, then every root's. Blocking file system work.
    nonisolated private static func snapshot(_ dir: URL, _ roots: [(url: URL, bookmark: Data, isDirectory: Bool)]) -> Snapshot {
        let fm = FileManager.default
        var files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["cbz", "zip", "pdf"].contains($0.pathExtension.lowercased()) }
        var sources: [URL: URL] = [:]
        for root in roots {
            // A folder's kind is decided on every scan: an empty one later filled with images becomes one
            // comic, and a comic's folder that gains an archive becomes a folder of comics.
            let found = !root.isDirectory ? (fm.fileExists(atPath: root.url.path) ? [root.url] : [])
                : FolderComic.isComic(root.url) ? [root.url] : scan(root.url)
            for url in found where sources[url] == nil {
                sources[url] = root.url
                files.append(url)
            }
        }
        return Snapshot(comics: files, sources: sources,
                        keys: Dictionary(files.map { ($0, ReadingProgress.key($0)) }, uniquingKeysWith: { a, _ in a }),
                        revisions: Dictionary(files.compactMap { url in ReadingProgress.revision(url).map { (url, $0) } },
                                              uniquingKeysWith: { a, _ in a }))
    }

    // Published only when changed: an unchanged rescan would redraw every library window for nothing.
    private func apply(_ found: Snapshot) {
        sources = found.sources
        if comics != found.comics { comics = found.comics }
        if keys != found.keys { keys = found.keys }
        if revisions != found.revisions { revisions = found.revisions }
        readInfo()
    }

    /// Comics new to the library sort first under Recent, like a fresh import; one opened before keeps its time.
    private func markNew(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let opened = ReadingProgress.openedMap()
        for url in urls where keys[url].map({ opened[$0] == nil }) == true { ReadingProgress.markOpened(url) }
    }

    /// A watched folder's comics: archives anywhere under it, and each subfolder holding only images as one comic.
    nonisolated private static func scan(_ folder: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        while let url = walk.nextObject() as? URL {
            if inPlaceExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, FolderComic.isComic(url) {
                found.append(url)
                walk.skipDescendants()
            }
        }
        return found
    }

    /// Imports off the main thread; `read` gets the copy once it is in the library. A folder with no pages
    /// of its own imports every comic under it (archives, and folders of images), one after another.
    /// The returned task lets tests await completion; the UI ignores it.
    @discardableResult
    func importComic(from url: URL, then read: ((URL) -> Void)? = nil) -> Task<Void, Never> {
        activeImports += 1
        importing = true
        let dir = dir
        return Task {
            let scoped = url.startAccessingSecurityScopedResource()   // a folder's, for the comics inside it
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let items = await Task.detached(priority: .userInitiated) { Self.importables(url) }.value
            if items.isEmpty { report("Couldn't import \(url.lastPathComponent): \(ImportError.emptyFolder.localizedDescription)") }
            var imported: URL?
            for item in items {
                do {
                    let dest = try await Task.detached(priority: .userInitiated) { try Self.install(item, into: dir) }.value
                    ReadingProgress.markOpened(dest)   // fresh import sorts to the top
                    BookPredetector.shared.add(dest)   // its panels are ready before it is first opened
                    imported = dest
                } catch {
                    report("Couldn't import \(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
            activeImports -= 1
            importing = activeImports > 0
            refresh()
            if let imported { read?(imported) }
        }
    }

    /// What importing `url` brings in: the file, a folder's own images as one comic, or (a folder with
    /// none) every comic under it, in name order.
    nonisolated private static func importables(_ url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let pages = try? FolderComic.pages(in: url), pages.isEmpty else { return [url] }
        return scan(url).sorted { NaturalOrder.isOrderedBefore($0.path, $1.path) }
    }

    /// A comic opened from Finder (Open With, a double-click): one the library already has (read in
    /// place) opens as it is, any other file is imported and then opened; a folder is added in place.
    /// Returns the import, if any, for tests to await.
    @discardableResult
    func open(fromFinder url: URL, read: @escaping (URL) -> Void) -> Task<Void, Never>? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { addInPlace(url); return nil }
        let key = ReadingProgress.key(url)
        if let known = comics.first(where: { keys[$0] == key }) { read(known); return nil }
        return importComic(from: url, then: read)
    }

    /// An imported copy: a file in the library's own folder, the only kind of comic ever deleted.
    func isImportedCopy(_ url: URL) -> Bool {
        sources[url] == nil && url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path
    }

    /// An imported copy is deleted. A comic read in place only leaves the library: its bookmark (or
    /// its whole watched folder) is forgotten and the user's file is never touched.
    func delete(_ url: URL) {
        // Before its rows are cleared, so no late detection lands; Stop Watching drops every comic of the folder.
        let gone = sources[url].map { root in sources.filter { $0.value == root }.map(\.key) } ?? [url]
        gone.forEach(BookPredetector.shared.cancel)
        if let root = sources[url] {
            roots.removeAll { $0.url == root }
            saveBookmarks()
            watch()
        } else if isImportedCopy(url) {
            let key = ReadingProgress.key(url)   // read from the file, so taken while it is there
            do {
                try FileManager.default.removeItem(at: url)
                ReadingProgress.clear(key: key)   // only once the comic is really gone
            } catch {
                report("Couldn't remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Neither: it already left the library (another window removed it, or its folder changed), and a
        // file outside the library's folder is never ours to delete.
        for url in gone {
            CoverLoader.evict(url)
            info[url] = nil   // a later import under the same name reads its own
            infoRead.remove(url)
        }
        refresh()
    }

    // MARK: - Reopen at launch

    /// A reader window appeared: the comic counts as just opened (unless reopened at launch, so Open Last
    /// Comic and the library's order still see the last comic the user opened) and joins the session.
    func readerOpened(_ url: URL) {
        if reopening.remove(url) == nil { ReadingProgress.markOpened(url) }
        guard keepsSession else { return }
        openComics.removeAll { $0 == url }
        openComics.append(url)
        saveOpenComics()
    }

    func readerClosed(_ url: URL) {
        guard keepsSession, !quitting else { return }
        openComics.removeAll { $0 == url }
        saveOpenComics()
    }

    // Identities, not paths: a comic renamed or moved (or its watched folder) still reopens.
    private func saveOpenComics() {
        defaults.set(openComics.map { keys[$0] ?? ReadingProgress.key($0) }, forKey: Self.openComicsKey)
    }

    /// The comics whose readers were open at the last quit and are still in the library, in the order
    /// they opened. Once per launch: a library window opened later gets none.
    func takeComicsToReopen() -> [URL] {
        defer { toReopen = [] }
        let urls = toReopen.compactMap { key in comics.first { keys[$0] == key } }
        reopening.formUnion(urls)
        return urls
    }

    // MARK: - Series

    /// Reads ComicInfo.xml once per comic, off the main thread, each comic's shown as soon as it is read.
    /// A comic that can't be read yet (still being copied in) is read again on a later scan.
    // shortcut: keyed by URL, so editing a comic's ComicInfo.xml shows after a relaunch; key by
    // modification date if anyone edits metadata while Chika runs.
    private func readInfo() {
        let pending = comics.filter { !infoRead.contains($0) }
        guard !pending.isEmpty else { return }
        infoRead.formUnion(pending)
        let previous = infoTask
        infoTask = Task {
            await previous?.value   // in order, so a comic removed and added again under its name ends with its own
            for url in pending {
                let read = await Task.detached(priority: .utility) { Result { try ComicOpener.comicInfo(url) } }.value
                guard infoRead.contains(url) else { continue }   // removed meanwhile
                switch read {
                case .success(let found): if info[url] != found { info[url] = found }
                case .failure: infoRead.remove(url)
                }
            }
        }
    }

    /// The next issue of `url`'s series in the library, by ComicInfo volume and number.
    func nextIssue(after url: URL) -> URL? {
        guard let current = info[url] else { return nil }
        let candidates = comics.filter { $0 != url && info[$0] != nil }
        return ComicInfo.next(after: current, in: candidates.map { info[$0]! }).map { candidates[$0] }
    }

    /// Comics grouped by series (alphabetical, issues in order), then the comics with no series
    /// under a nil title, in their incoming order.
    static func seriesGroups(_ comics: [URL], info: [URL: ComicInfo]) -> [(series: String?, comics: [URL])] {
        var groups: [String: [URL]] = [:]
        var loose: [URL] = []
        for url in comics {
            if let series = info[url]?.series { groups[series.lowercased(), default: []].append(url) } else { loose.append(url) }
        }
        let series = groups.values
            .map { urls in (series: info[urls[0]]?.series, comics: urls.sorted { ComicInfo.issueOrder(info[$0]!, info[$1]!) }) }
            .sorted { $0.series!.localizedStandardCompare($1.series!) == .orderedAscending }
        return loose.isEmpty ? series : series + [(nil, loose)]
    }

    // MARK: - Search, sort, filter

    enum Sort: String, CaseIterable { case recent = "Recent", title = "Title", series = "Series", unread = "Unread" }

    /// What the grid shows: comics matching `query` (title, series or writer), optionally only the
    /// unfinished ones, ordered by `sort`. Series sort returns series sections; the rest one nil section.
    static func arrange(_ comics: [URL], query: String, sort: Sort, unreadOnly: Bool, keys: [URL: String],
                        progress: [String: Progress], opened: [String: Double],
                        info: [URL: ComicInfo]) -> [(series: String?, comics: [URL])] {
        let title = { (url: URL) in url.comicTitle }
        let read = { (url: URL) in keys[url].flatMap { progress[$0] }?.fraction ?? 0 }
        let query = query.trimmingCharacters(in: .whitespaces)
        let shown = comics
            .filter { url in
                query.isEmpty || [title(url), info[url]?.series, info[url]?.writer].contains { $0?.localizedCaseInsensitiveContains(query) == true }
            }
            .filter { !unreadOnly || read($0) < 1 }
            .sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
        switch sort {
        case .series: return seriesGroups(shown, info: info)
        case .title: return [(nil, shown)]
        // Stable sorts over the title order, so ties stay alphabetical.
        case .recent:
            let time = { (url: URL) in keys[url].flatMap { opened[$0] } ?? 0 }
            return [(nil, shown.enumerated().sorted { (time($0.1), -$0.0) > (time($1.1), -$1.0) }.map(\.1))]
        case .unread:
            return [(nil, shown.enumerated().sorted { (read($0.1), $0.0) < (read($1.1), $1.0) }.map(\.1))]
        }
    }

    /// The "Continue reading" row: comics started (a panel or page read) but not read to the last
    /// page, most recently opened first.
    static func continueReading(_ comics: [URL], keys: [URL: String], progress: [String: Progress],
                                opened: [String: Double]) -> [URL] {
        comics
            .compactMap { url in keys[url].flatMap { key in progress[key].map { (url: url, p: $0, time: opened[key] ?? 0) } } }
            .filter { $0.p.started && $0.p.page + 1 < $0.p.total }
            .sorted { $0.time > $1.time }
            .map(\.url)
    }

    /// The comic opened most recently (an import counts), for Shortcuts' Open Last Comic.
    static func lastOpened(_ comics: [URL], keys: [URL: String], opened: [String: Double]) -> URL? {
        comics.compactMap { url in keys[url].flatMap { opened[$0] }.map { (url: url, time: $0) } }.max { $0.time < $1.time }?.url
    }

    // MARK: - Read in place

    /// A dropped or opened folder is read in place (watched, or one comic when it holds only images);
    /// a file is imported as a copy.
    func add(_ url: URL) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isFolder { addInPlace(url) } else { importComic(from: url) }
    }

    /// Adds a comic file or a folder to watch without copying it. Picked and dropped URLs carry a
    /// sandbox extension; the bookmark keeps that access across launches.
    func addInPlace(_ url: URL) {
        guard !roots.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
            report("“\(url.lastPathComponent)” is already in your library.")
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            resolve(data)
            saveBookmarks()
            watch()
            let before = Set(comics)
            refresh()
            markNew(comics.filter { !before.contains($0) })
        } catch {
            report("Couldn't add \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Resolves a bookmark and starts (and keeps, for the app's lifetime) its security scope. True when
    /// it was stale and has been refreshed, so the caller saves the list.
    @discardableResult
    private func resolve(_ data: Data) -> Bool {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else {
            unresolved.append(data)
            return false
        }
        _ = url.startAccessingSecurityScopedResource()
        let fresh = stale ? (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data : data
        roots.append((url, fresh, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true))
        return stale
    }

    /// A folder or file read in place that was renamed or moved while Chika runs is found again through
    /// its bookmark, so its comics don't vanish until a relaunch.
    private func followMovedRoots() {
        var moved = false
        for i in roots.indices where !FileManager.default.fileExists(atPath: roots[i].url.path) {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: roots[i].bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                  url.path != roots[i].url.path, FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            roots[i] = (url, fresh ?? roots[i].bookmark, roots[i].isDirectory)
            moved = true
        }
        if moved {
            saveBookmarks()
            watch()   // the stream watches paths: point it at the new one
        }
    }

    private func saveBookmarks() { defaults.set(roots.map(\.bookmark) + unresolved, forKey: Self.bookmarksKey) }

    /// One FSEvents stream over every folder added (recursive), so new comics appear by themselves. It
    /// also reports a watched folder itself being renamed or moved (WatchRoot), which the rescan follows.
    private func watch() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
        let folders = roots.filter(\.isDirectory).map(\.url.path)
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<LibraryStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { _ = store.refreshSoon() }
        }, &context, folders as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)   // the callback's assumeIsolated relies on this
            FSEventStreamStart(stream)
        }
    }

    private enum ImportError: LocalizedError {
        case unsupported, noImages, emptyFolder, incompleteFolder
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Choose a CBZ, CBR, CB7, PDF, ZIP, RAR or 7z comic, or a folder of images."
            case .noImages: return "No image pages found in this archive."
            case .emptyFolder: return "No comics or images found in this folder."
            case .incompleteFolder: return "Not every image in this folder could be copied."
            }
        }
    }

    /// Stage, convert and validate, then move into `dir`. A failed import leaves the library untouched.
    nonisolated private static func install(_ url: URL, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // On the library's volume, so the final rename below is atomic.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dir, create: true)
        defer { try? fm.removeItem(at: staging) }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        var folderPages = 0
        let source = staging.appendingPathComponent("source").appendingPathExtension(url.pathExtension)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readableURL in
            do {
                if isFolder {
                    // Only its pages, as the folder reads in place: subfolders and other files stay behind.
                    let pages = try FolderComic.pages(in: readableURL)
                    guard !pages.isEmpty else { throw ImportError.emptyFolder }
                    folderPages = pages.count
                    try fm.createDirectory(at: source, withIntermediateDirectories: false)
                    for page in pages { try fm.copyItem(at: page, to: source.appendingPathComponent(page.lastPathComponent)) }
                } else {
                    try fm.copyItem(at: readableURL, to: source)
                }
            } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }

        // Route by magic bytes (extension is only the fallback), matching Android's
        // ComicArchiveFactory, so a mislabeled ".cbz" that is really a RAR is converted.
        let format: ComicFormat = isFolder ? .cbz
            : ComicFormatDetector.detect(head: ComicOpener.leadingBytes(of: source), fileExtension: url.pathExtension)
        let ready = staging.appendingPathComponent("ready").appendingPathExtension(format == .pdf ? "pdf" : "cbz")
        switch format {
        case .cbr, .cb7: try CbrConverter.convertToCbz(source: source, destination: ready)
        // Pages are already compressed: store them.
        case .cbz where isFolder: try fm.zipItem(at: source, to: ready, shouldKeepParent: false, compressionMethod: .none)
        case .cbz, .pdf: try fm.moveItem(at: source, to: ready)
        case .unknown: throw ImportError.unsupported
        }
        let pageCount = try ComicOpener.open(ready).pageCount
        guard pageCount > 0 else { throw isFolder ? ImportError.emptyFolder : ImportError.noImages }
        // Every page copied from a folder must have made it into the archive.
        guard !isFolder || pageCount == folderPages else { throw ImportError.incompleteFolder }

        let base = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let dest = dir.appendingPathComponent(n == 1 ? base : "\(base) \(n)").appendingPathExtension(ready.pathExtension)
            // RENAME_EXCL fails instead of replacing, so even two concurrent imports never clobber.
            if renamex_np(ready.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return dest }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            n += 1
        }
    }
}
