import Foundation
import CoreServices
import UniformTypeIdentifiers
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
    private var roots: [(url: URL, bookmark: Data, isFolder: Bool)] = []
    private var unresolved: [Data] = []
    private var stream: FSEventStreamRef?
    private static let bookmarksKey = "chika.bookmarks.v1"
    static let inPlaceExtensions: Set = ["cbz", "cbr"]

    /// Types the file importer allows. Includes the app's exported CBZ/CBR types plus the generic
    /// zip/archive/rar families so a plain .zip or .rar comic is selectable too.
    static var importableTypes: [UTType] {
        var types: [UTType] = [.zip, .archive]
        if let cbz = UTType("com.chakra.comicreader.cbz") { types.append(cbz) }
        if let cbr = UTType("com.chakra.comicreader.cbr") { types.append(cbr) }
        if let rar = UTType("com.rarlab.rar-archive") { types.append(rar) }
        // macOS may associate these extensions with types declared by another installed reader.
        for ext in ["cbz", "cbr", "rar"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// `directory` overrides the library folder and `defaults` the bookmark store (tests pass their own).
    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ReadingProgress.migrateLegacy(in: dir)
        // shortcut: a bookmark that no longer resolves (file deleted, drive unplugged) is kept but
        // hidden, so a drive that comes back reappears; add a "missing" row if that confuses anyone.
        for data in defaults.array(forKey: Self.bookmarksKey) as? [Data] ?? [] { resolve(data) }
        watch()
        refresh()
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }

    // shortcut: scans on the main thread; move off it if watched folders grow to many thousands of files.
    func refresh() {
        let fm = FileManager.default
        var files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["cbz", "zip"].contains($0.pathExtension.lowercased()) }
        sources = [:]
        for root in roots {
            let found = root.isFolder
                ? (fm.enumerator(at: root.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                    .compactMap { $0 as? URL }
                    .filter { Self.inPlaceExtensions.contains($0.pathExtension.lowercased()) } ?? [])
                : (fm.fileExists(atPath: root.url.path) ? [root.url] : [])
            for url in found where sources[url] == nil {
                sources[url] = root.url
                files.append(url)
            }
        }
        let opened = ReadingProgress.openedMap()
        comics = files
            .map { ($0, opened[ReadingProgress.key($0)] ?? 0) }
            // Most-recently-opened first (Android's `ORDER BY lastOpened DESC`), then natural filename.
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending
            }
            .map(\.0)
        readInfo()
    }

    /// Imports off the main thread. The returned task lets tests await completion; the UI ignores it.
    @discardableResult
    func importComic(from url: URL) -> Task<Void, Never> {
        activeImports += 1
        importing = true
        let dir = dir
        return Task {
            do {
                let dest = try await Task.detached(priority: .userInitiated) { try Self.install(url, into: dir) }.value
                ReadingProgress.markOpened(dest)   // fresh import sorts to the top
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
            activeImports -= 1
            importing = activeImports > 0
            refresh()
        }
    }

    /// An imported copy is deleted. A comic read in place only leaves the library: its bookmark (or
    /// its whole watched folder) is forgotten and the user's file is never touched.
    func delete(_ url: URL) {
        if let root = sources[url] {
            roots.removeAll { $0.url == root }
            saveBookmarks()
            watch()
        } else {
            ReadingProgress.clear(url)   // first: its key is read from the file
            try? FileManager.default.removeItem(at: url)
        }
        CoverLoader.evict(url)
        refresh()
    }

    // MARK: - Series

    /// Reads ComicInfo.xml once per comic, off the main thread.
    // shortcut: keyed by URL, so editing a comic's ComicInfo.xml shows after a relaunch; key by
    // modification date if anyone edits metadata while Chika runs.
    private func readInfo() {
        let pending = comics.filter { !infoRead.contains($0) }
        guard !pending.isEmpty else { return }
        infoRead.formUnion(pending)
        infoTask = Task {
            let found = await Task.detached(priority: .utility) {
                pending.reduce(into: [URL: ComicInfo]()) { map, url in map[url] = (try? ComicOpener.open(url))?.comicInfo }
            }.value
            info.merge(found) { $1 }
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

    // MARK: - Read in place

    /// Adds a comic file or a folder to watch without copying it. Picked and dropped URLs carry a
    /// sandbox extension; the bookmark keeps that access across launches.
    func addInPlace(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            guard !roots.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
            resolve(data)
            saveBookmarks()
            watch()
            refresh()
        } catch {
            importError = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Resolves a bookmark and starts (and keeps, for the app's lifetime) its security scope.
    private func resolve(_ data: Data) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else {
            unresolved.append(data)
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        let fresh = stale ? (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data : data
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        roots.append((url, fresh, isFolder))
        if stale { saveBookmarks() }
    }

    private func saveBookmarks() { defaults.set(roots.map(\.bookmark) + unresolved, forKey: Self.bookmarksKey) }

    /// One FSEvents stream over every watched folder (recursive), so new comics appear by themselves.
    private func watch() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
        let folders = roots.filter(\.isFolder).map(\.url.path)
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<LibraryStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.refresh() }
        }, &context, folders as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)   // the callback's assumeIsolated relies on this
            FSEventStreamStart(stream)
        }
    }

    private enum ImportError: LocalizedError {
        case unsupported, noImages
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Choose a CBZ, CBR, ZIP, or RAR comic archive."
            case .noImages: return "No image pages found in this archive."
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
        let source = staging.appendingPathComponent("source").appendingPathExtension(url.pathExtension)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readableURL in
            do { try fm.copyItem(at: readableURL, to: source) }
            catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }

        // Route by magic bytes (extension is only the fallback), matching Android's
        // ComicArchiveFactory, so a mislabeled ".cbz" that is really a RAR is converted.
        let ready = staging.appendingPathComponent("ready.cbz")
        switch ComicFormatDetector.detect(head: ComicOpener.leadingBytes(of: source), fileExtension: url.pathExtension) {
        case .cbr: try CbrConverter.convertToCbz(source: source, destination: ready)
        case .cbz: try fm.moveItem(at: source, to: ready)
        case .unknown: throw ImportError.unsupported
        }
        guard try CbzArchive(url: ready).pageCount > 0 else { throw ImportError.noImages }

        let base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let dest = dir.appendingPathComponent(n == 1 ? "\(base).cbz" : "\(base) \(n).cbz")
            // RENAME_EXCL fails instead of replacing, so even two concurrent imports never clobber.
            if renamex_np(ready.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return dest }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            n += 1
        }
    }
}
