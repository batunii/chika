import Foundation
import SQLite3
import os
import ChikaCore

/// Per-comic reading progress (resume point + total): the counterpart to Android's Room-backed
/// resume (page *and* panel).
struct Progress: Codable, Equatable {
    var page: Int
    var step: Int      // -1 = whole page, else panel index
    var total: Int     // page count, for the library progress readout
    // Reading direction for THIS comic. nil means "never chosen for this comic" → fall back to the
    // global default.
    var rtl: Bool?
    var mode: String?  // ReadingMode raw value; nil = never chosen → panels

    /// Read past the opening: a later page, or a panel of the first. One rule for the cards, the Unread
    /// sort and Continue reading, so an opened but unread comic is unread everywhere.
    var started: Bool { page > 0 || step >= 0 }
    /// How far through once started, page 0 counting as page 1 (Android's fill); 0 before.
    var fraction: Double { started && total > 0 ? min(Double(page + 1) / Double(total), 1) : 0 }
}

/// A spot the reader marked in a comic: a page and its panel (-1 = the whole page).
struct Bookmark: Hashable {
    var page: Int
    // shortcut: step is a panel index in the reading direction (and panel edits) at the time; a direction flip or a panel edit moves it to another panel. Store the panel's rect if that bites.
    var step: Int
}

/// Progress and last-opened time in one small SQLite table keyed by file identity (volume UUID +
/// inode), so a comic keeps its place when it is renamed or moved on its volume. Not
/// `fileResourceIdentifierKey`: Apple documents that one as not persistent across restarts.
enum ReadingProgress {
    /// Posted after writes (at most twice a second) so the library re-sorts and refreshes its cards.
    static let didChange = Notification.Name("chika.readingProgressDidChange")
    /// Posted once per database when saving progress fails, with the reason as the object, so the library can say so.
    static let saveDidFail = Notification.Name("chika.readingProgressSaveDidFail")
    // `var` so tests can point these at their own store instead of the real app data.
    static var databaseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Chika/progress.sqlite")
    static var defaults = UserDefaults.standard

    private static var connection: (url: URL, db: OpaquePointer)?
    private static let log = Logger(subsystem: "com.chakra.comicreader", category: "progress")
    private static var lastError = "the progress database could not be opened"
    private static var reportedFailure: URL?
    private static var changePending = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The table key for a comic. Falls back to the path when the volume has no stable inode/UUID.
    static func key(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey])
        if let volume = values?.volumeUUIDString, let id = values?.fileIdentifier { return "\(volume):\(id)" }
        return url.standardizedFileURL.path
    }

    /// The file's size and modification date. Detections and balloon texts are stored with it and only
    /// read back while it matches: a comic edited in place (a page inserted) keeps its inode, so its key.
    /// Nil when the file is gone. Not resourceValues: a long-lived URL caches those.
    static func revision(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, let date = attributes[.modificationDate] as? Date else { return nil }
        return "\(size):\(date.timeIntervalSince1970)"
    }

    /// Every comic's progress keyed by `key(_:)`. Read once, look up many (the library cards).
    static func all() -> [String: Progress] {
        var map: [String: Progress] = [:]
        run("SELECT id, page, step, total, rtl, mode FROM progress") { row in
            if let p = progress(row, from: 1) { map[String(cString: sqlite3_column_text(row, 0))] = p }
        }
        return map
    }

    static func get(_ url: URL) -> Progress? {
        var found: Progress?
        run("SELECT page, step, total, rtl, mode FROM progress WHERE id = ?", [key(url)]) { found = progress($0, from: 0) }
        return found
    }

    /// Effective reading direction for a comic: its saved choice if any, else the global default.
    static func readingDirection(_ url: URL, default fallback: Bool) -> Bool { get(url)?.rtl ?? fallback }

    static func set(_ url: URL, page: Int, step: Int, total: Int, rtl: Bool, mode: String) {
        saved(run("""
            INSERT INTO progress(id, page, step, total, rtl, mode) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET page = excluded.page, step = excluded.step, total = excluded.total,
                rtl = excluded.rtl, mode = excluded.mode
            """, [key(url), page, step, total, rtl, mode]))
    }

    /// Everything stored for the comic whose `key(_:)` is `key`: take the key while the file is still there.
    static func clear(key: String) {
        for table in ["progress", "bookmarks", "panel_overrides", "detections", "balloon_text", "translations"] {
            run("DELETE FROM \(table) WHERE id = ?", [key])
        }
        changed()
    }

    // MARK: - Recency (most-recently-opened ordering, matching Android's `ORDER BY lastOpened DESC`)

    /// Records that a comic was just opened/imported, so the library can order by recency.
    static func markOpened(_ url: URL) {
        saved(run("""
            INSERT INTO progress(id, opened) VALUES(?, ?)
            ON CONFLICT(id) DO UPDATE SET opened = excluded.opened
            """, [key(url), Date().timeIntervalSince1970]))
    }

    /// Last-opened timestamps keyed by `key(_:)` (missing = never opened), the library sort key.
    static func openedMap() -> [String: Double] {
        var map: [String: Double] = [:]
        run("SELECT id, opened FROM progress WHERE opened IS NOT NULL") { row in
            map[String(cString: sqlite3_column_text(row, 0))] = sqlite3_column_double(row, 1)
        }
        return map
    }

    // MARK: - Bookmarks

    /// A comic's bookmarks in reading order.
    static func bookmarks(_ url: URL) -> [Bookmark] {
        var marks: [Bookmark] = []
        run("SELECT page, step FROM bookmarks WHERE id = ? ORDER BY page, step", [key(url)]) { row in
            marks.append(Bookmark(page: Int(sqlite3_column_int64(row, 0)), step: Int(sqlite3_column_int64(row, 1))))
        }
        return marks
    }

    /// Adds the bookmark at (page, step), or removes it if it is already there.
    static func toggleBookmark(_ url: URL, page: Int, step: Int) {
        guard let db else { return }
        let args: [Any?] = [key(url), page, step]
        run("DELETE FROM bookmarks WHERE id = ? AND page = ? AND step = ?", args)
        if sqlite3_changes(db) == 0 {
            run("INSERT INTO bookmarks(id, page, step) VALUES(?, ?, ?)", args)
        }
    }

    // MARK: - Panel overrides (the panel editor)

    /// The panels drawn by hand for a page, in reading order; nil = none, detection decides.
    static func panelOverride(_ url: URL, page: Int) -> [Panel]? {
        var json: String?
        run("SELECT panels FROM panel_overrides WHERE id = ? AND page = ?", [key(url), page]) { row in
            json = sqlite3_column_text(row, 0).map { String(cString: $0) }
        }
        return json.flatMap { try? JSONDecoder().decode([Panel].self, from: Data($0.utf8)) }
    }

    /// Stores `panels` as the page's override; `drawn` = every box was drawn by hand (training export).
    /// False if it was not written, so the editor keeps the edits.
    @discardableResult
    static func setPanelOverride(_ url: URL, page: Int, panels: [Panel], drawn: Bool = false) -> Bool {
        guard let json = try? JSONEncoder().encode(panels) else { return false }
        return run("INSERT OR REPLACE INTO panel_overrides(id, page, panels, drawn) VALUES(?, ?, ?, ?)",
                   [key(url), page, String(decoding: json, as: UTF8.self), drawn])
    }

    /// Whether every box of the page's override was drawn by hand.
    static func panelsDrawn(_ url: URL, page: Int) -> Bool {
        var drawn = false
        run("SELECT drawn FROM panel_overrides WHERE id = ? AND page = ?", [key(url), page]) { drawn = sqlite3_column_int64($0, 0) != 0 }
        return drawn
    }

    /// False if it was not deleted, so the edit is kept.
    @discardableResult
    static func deletePanelOverride(_ url: URL, page: Int) -> Bool {
        run("DELETE FROM panel_overrides WHERE id = ? AND page = ?", [key(url), page])
    }

    /// Every saved override (comic key, page, panels, all drawn by hand), grouped by comic and in page
    /// order, for the training export.
    static func allPanelOverrides() -> [(id: String, page: Int, panels: [Panel], drawn: Bool)] {
        var rows: [(id: String, page: Int, panels: [Panel], drawn: Bool)] = []
        run("SELECT id, page, panels, drawn FROM panel_overrides ORDER BY id, page") { row in
            guard let json = sqlite3_column_text(row, 2).map({ String(cString: $0) }),
                  let panels = try? JSONDecoder().decode([Panel].self, from: Data(json.utf8)) else { return }
            rows.append((String(cString: sqlite3_column_text(row, 0)), Int(sqlite3_column_int64(row, 1)), panels,
                         sqlite3_column_int64(row, 3) != 0))
        }
        return rows
    }

    // MARK: - Stored detections (instant reopen, background pre-detection)

    /// A page's stored zoom regions for one reading direction and its speech balloons; nil when it
    /// was never detected or was detected by another detector `version` or from another `revision(_:)`.
    /// `revision` is the caller's `revision(_:)` of the file, taken once rather than on every page.
    static func detection(_ url: URL, page: Int, rtl: Bool, revision: String?,
                          version: Int = CoreMLPanelDetector.version) -> (regions: [Panel], bubbles: [Panel])? {
        var found: (regions: [Panel], bubbles: [Panel])?
        run("SELECT regions, bubbles FROM detections WHERE id = ? AND page = ? AND rtl = ? AND version = ? AND rev = ?",
            [key(url), page, rtl, version, revision]) { row in
            let decode = { (col: Int32) in
                sqlite3_column_text(row, col).flatMap { try? JSONDecoder().decode([Panel].self, from: Data(String(cString: $0).utf8)) }
            }
            if let regions = decode(0), let bubbles = decode(1) { found = (regions, bubbles) }
        }
        return found
    }

    /// Stores a page's detection, one row per reading direction, replacing any older version's.
    /// `revision` is the file's `revision(_:)` from before the page was read: nothing is stored once the
    /// file has changed or gone since (an edit, or a delete with the reader's work still queued).
    static func setDetection(_ url: URL, page: Int, _ detection: PageDetection, revision: String?,
                             version: Int = CoreMLPanelDetector.version) {
        guard let revision, revision == Self.revision(url) else { return }
        let encode = { (panels: [Panel]) in (try? JSONEncoder().encode(panels)).map { String(decoding: $0, as: UTF8.self) } }
        let id = key(url)
        run("BEGIN")
        for rtl in [false, true] {
            run("INSERT OR REPLACE INTO detections(id, page, rtl, version, regions, bubbles, rev) VALUES(?, ?, ?, ?, ?, ?, ?)",
                [id, page, rtl, version, encode(detection.regions(rightToLeft: rtl)), encode(detection.bubbles), revision])
        }
        run("COMMIT")
    }

    /// The pages stored in both reading directions by this detector `version` from the file as it is now.
    static func detectedPages(_ url: URL, revision: String?, version: Int = CoreMLPanelDetector.version) -> Set<Int> {
        var pages: Set<Int> = []
        run("SELECT page FROM detections WHERE id = ? AND version = ? AND rev = ? GROUP BY page HAVING COUNT(*) = 2",
            [key(url), version, revision]) { row in
            pages.insert(Int(sqlite3_column_int64(row, 0)))
        }
        return pages
    }

    // MARK: - Balloon text and translations (Translate)

    /// A page's recognized balloon texts keyed by balloon box, read by text recognizer `version`.
    /// Keyed by the box, not its index, so rows from an older detector's balloons simply never match.
    static func balloonTexts(_ url: URL, page: Int, revision: String?, version: Int = BalloonReader.version) -> [Panel: String] {
        var texts: [Panel: String] = [:]
        run("SELECT box, text FROM balloon_text WHERE id = ? AND page = ? AND version = ? AND rev = ?",
            [key(url), page, version, revision]) { row in
            guard let box = sqlite3_column_text(row, 0).flatMap({ try? JSONDecoder().decode(Panel.self, from: Data(String(cString: $0).utf8)) })
            else { return }
            texts[box] = String(cString: sqlite3_column_text(row, 1))
        }
        return texts
    }

    /// `revision` as for `setDetection`.
    static func setBalloonText(_ url: URL, page: Int, box: Panel, text: String, revision: String?, version: Int = BalloonReader.version) {
        guard let revision, revision == Self.revision(url), let json = try? JSONEncoder().encode(box) else { return }
        run("INSERT OR REPLACE INTO balloon_text(id, page, box, version, text, rev) VALUES(?, ?, ?, ?, ?, ?)",
            [key(url), page, String(decoding: json, as: UTF8.self), version, text, revision])
    }

    /// The stored translation of a comic's balloon text from language `from` (nil: not recognized)
    /// into `target` (BCP 47 identifiers).
    static func translation(_ url: URL, source: String, from: String?, target: String) -> String? {
        var found: String?
        run("SELECT text FROM translations WHERE id = ? AND source = ? AND target = ?", [key(url), source, pair(from, target)]) { row in
            found = String(cString: sqlite3_column_text(row, 0))
        }
        return found
    }

    static func setTranslation(_ url: URL, source: String, from: String?, target: String, text: String) {
        run("INSERT OR REPLACE INTO translations(id, source, target, text) VALUES(?, ?, ?, ?)", [key(url), source, pair(from, target), text])
    }

    /// The target column holds "from>target": rows from before it (one source language per batch, so
    /// possibly mistranslated) never match and are translated again.
    private static func pair(_ from: String?, _ target: String) -> String { "\(from ?? "")>\(target)" }

    // MARK: - Migration

    /// One-time copy of the old filename-keyed UserDefaults JSON into the table, for the files in
    /// `dir`. The old keys stay: the Catalyst app shares this container and still reads them.
    static func migrateLegacy(in dir: URL) {
        let doneKey = "chika.progress.sqliteMigrated"
        guard !defaults.bool(forKey: doneKey), db != nil else { return }
        let decoder = JSONDecoder()
        let progress = defaults.data(forKey: "chika.progress.v1")
            .flatMap { try? decoder.decode([String: Progress].self, from: $0) } ?? [:]
        let opened = defaults.data(forKey: "chika.lastOpened.v1")
            .flatMap { try? decoder.decode([String: Double].self, from: $0) } ?? [:]
        run("BEGIN")
        for name in Set(progress.keys).union(opened.keys) {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let p = progress[name]
            run("INSERT OR IGNORE INTO progress(id, page, step, total, rtl, opened) VALUES(?, ?, ?, ?, ?, ?)",
                [key(url), p?.page, p?.step, p?.total, p?.rtl, opened[name]])
        }
        run("COMMIT")
        defaults.set(true, forKey: doneKey)
    }

    // MARK: - SQLite

    private static var db: OpaquePointer? {
        if let connection, connection.url == databaseURL { return connection.db }
        if let old = connection { sqlite3_close(old.db); connection = nil }
        try? FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            failed(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory", "opening \(databaseURL.path)")
            sqlite3_close(handle)
            return nil
        }
        // page/step/total are NULL for a comic that was opened but never read; rtl NULL = never chosen.
        let schema = sqlite3_exec(handle, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS progress(id TEXT PRIMARY KEY, page INTEGER, step INTEGER, total INTEGER, rtl INTEGER, opened REAL);
            CREATE TABLE IF NOT EXISTS bookmarks(id TEXT, page INTEGER, step INTEGER, PRIMARY KEY(id, page, step));
            CREATE TABLE IF NOT EXISTS panel_overrides(id TEXT, page INTEGER, panels TEXT NOT NULL, PRIMARY KEY(id, page));
            CREATE TABLE IF NOT EXISTS detections(id TEXT, page INTEGER, rtl INTEGER, version INTEGER,
                regions TEXT NOT NULL, bubbles TEXT NOT NULL, PRIMARY KEY(id, page, rtl));
            CREATE TABLE IF NOT EXISTS balloon_text(id TEXT, page INTEGER, box TEXT, version INTEGER, text TEXT NOT NULL,
                PRIMARY KEY(id, page, box));
            CREATE TABLE IF NOT EXISTS translations(id TEXT, source TEXT, target TEXT, text TEXT NOT NULL, PRIMARY KEY(id, source, target));
            """, nil, nil, nil)
        if schema != SQLITE_OK { failed(String(cString: sqlite3_errmsg(handle)), "creating the tables") }
        // Added in phase 3; each fails harmlessly once the column exists. drawn NULL (an edit saved before it) = not drawn.
        sqlite3_exec(handle, "ALTER TABLE progress ADD COLUMN mode TEXT", nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE panel_overrides ADD COLUMN drawn INTEGER", nil, nil, nil)
        // Rows from before rev existed (NULL) never match, so those pages are read again.
        sqlite3_exec(handle, "ALTER TABLE detections ADD COLUMN rev TEXT", nil, nil, nil)
        sqlite3_exec(handle, "ALTER TABLE balloon_text ADD COLUMN rev TEXT", nil, nil, nil)
        connection = (databaseURL, handle)
        return handle
    }

    /// Runs one statement with `args` bound in order, calling `row` for each result row. True if it ran to the end.
    @discardableResult
    private static func run(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var stmt: OpaquePointer?
        guard let db else { return false }   // opening it already logged why
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            failed(String(cString: sqlite3_errmsg(db)), sql)
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case let v as Bool: sqlite3_bind_int64(stmt, n, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            case let v as String: sqlite3_bind_text(stmt, n, v, -1, transient)
            default: sqlite3_bind_null(stmt, n)
            }
        }
        while true {
            let result = sqlite3_step(stmt)
            guard result == SQLITE_ROW else {
                if result != SQLITE_DONE { failed(String(cString: sqlite3_errmsg(db)), sql) }
                return result == SQLITE_DONE
            }
            row?(stmt)
        }
    }

    /// Logs a failed statement; its message is what a failed save reports.
    private static func failed(_ message: String, _ doing: String) {
        lastError = message
        log.error("SQLite failed (\(message, privacy: .public)) while \(doing, privacy: .public)")
    }

    /// A progress write landed (the library refreshes) or failed. A failure is said once per database:
    /// a full disk or a denied write would otherwise lose a whole session of reading without a word.
    private static func saved(_ ok: Bool) {
        guard !ok else { changed(); return }
        guard reportedFailure != databaseURL else { return }
        reportedFailure = databaseURL
        NotificationCenter.default.post(name: saveDidFail, object: lastError)
    }

    private static func progress(_ row: OpaquePointer, from col: Int32) -> Progress? {
        guard sqlite3_column_type(row, col) != SQLITE_NULL else { return nil }
        return Progress(page: Int(sqlite3_column_int64(row, col)),
                        step: Int(sqlite3_column_int64(row, col + 1)),
                        total: Int(sqlite3_column_int64(row, col + 2)),
                        rtl: sqlite3_column_type(row, col + 3) == SQLITE_NULL ? nil : sqlite3_column_int64(row, col + 3) != 0,
                        mode: sqlite3_column_text(row, col + 4).map { String(cString: $0) })
    }

    // Coalesced: a reader writes on every step, and each post makes the library re-read the whole table.
    private static func changed() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            changePending = false
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
