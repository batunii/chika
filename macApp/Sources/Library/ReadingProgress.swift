import Foundation
import SQLite3
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
    /// Posted after every write so the library re-sorts and refreshes its cards.
    static let didChange = Notification.Name("chika.readingProgressDidChange")
    // `var` so tests can point these at their own store instead of the real app data.
    static var databaseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Chika/progress.sqlite")
    static var defaults = UserDefaults.standard

    private static var connection: (url: URL, db: OpaquePointer)?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The table key for a comic. Falls back to the path when the volume has no stable inode/UUID.
    static func key(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey])
        if let volume = values?.volumeUUIDString, let id = values?.fileIdentifier { return "\(volume):\(id)" }
        return url.standardizedFileURL.path
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
        run("""
            INSERT INTO progress(id, page, step, total, rtl, mode) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET page = excluded.page, step = excluded.step, total = excluded.total,
                rtl = excluded.rtl, mode = excluded.mode
            """, [key(url), page, step, total, rtl, mode])
        changed()
    }

    /// Call before the file is gone: the key comes from the file itself.
    static func clear(_ url: URL) {
        run("DELETE FROM progress WHERE id = ?", [key(url)])
        run("DELETE FROM bookmarks WHERE id = ?", [key(url)])
        run("DELETE FROM panel_overrides WHERE id = ?", [key(url)])
        changed()
    }

    // MARK: - Recency (most-recently-opened ordering, matching Android's `ORDER BY lastOpened DESC`)

    /// Records that a comic was just opened/imported, so the library can order by recency.
    static func markOpened(_ url: URL) {
        run("""
            INSERT INTO progress(id, opened) VALUES(?, ?)
            ON CONFLICT(id) DO UPDATE SET opened = excluded.opened
            """, [key(url), Date().timeIntervalSince1970])
        changed()
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
            run("INSERT INTO bookmarks(id, page, step, created) VALUES(?, ?, ?, ?)", args + [Date().timeIntervalSince1970])
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

    /// Stores `panels` as the page's override. False if it was not written, so the editor keeps the edits.
    @discardableResult
    static func setPanelOverride(_ url: URL, page: Int, panels: [Panel]) -> Bool {
        guard let json = try? JSONEncoder().encode(panels) else { return false }
        return run("INSERT OR REPLACE INTO panel_overrides(id, page, panels) VALUES(?, ?, ?)",
                   [key(url), page, String(decoding: json, as: UTF8.self)])
    }

    static func deletePanelOverride(_ url: URL, page: Int) {
        run("DELETE FROM panel_overrides WHERE id = ? AND page = ?", [key(url), page])
    }

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
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else { sqlite3_close(handle); return nil }
        // page/step/total are NULL for a comic that was opened but never read; rtl NULL = never chosen.
        sqlite3_exec(handle, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS progress(id TEXT PRIMARY KEY, page INTEGER, step INTEGER, total INTEGER, rtl INTEGER, opened REAL);
            CREATE TABLE IF NOT EXISTS bookmarks(id TEXT, page INTEGER, step INTEGER, created REAL, PRIMARY KEY(id, page, step));
            CREATE TABLE IF NOT EXISTS panel_overrides(id TEXT, page INTEGER, panels TEXT NOT NULL, PRIMARY KEY(id, page));
            """, nil, nil, nil)
        // Added in phase 3; fails harmlessly once the column exists.
        sqlite3_exec(handle, "ALTER TABLE progress ADD COLUMN mode TEXT", nil, nil, nil)
        connection = (databaseURL, handle)
        return handle
    }

    /// Runs one statement with `args` bound in order, calling `row` for each result row. True if it ran to the end.
    @discardableResult
    private static func run(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
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
            guard result == SQLITE_ROW else { return result == SQLITE_DONE }
            row?(stmt)
        }
    }

    private static func progress(_ row: OpaquePointer, from col: Int32) -> Progress? {
        guard sqlite3_column_type(row, col) != SQLITE_NULL else { return nil }
        return Progress(page: Int(sqlite3_column_int64(row, col)),
                        step: Int(sqlite3_column_int64(row, col + 1)),
                        total: Int(sqlite3_column_int64(row, col + 2)),
                        rtl: sqlite3_column_type(row, col + 3) == SQLITE_NULL ? nil : sqlite3_column_int64(row, col + 3) != 0,
                        mode: sqlite3_column_text(row, col + 4).map { String(cString: $0) })
    }

    private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
}
