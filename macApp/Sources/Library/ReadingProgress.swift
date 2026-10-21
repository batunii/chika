import Foundation

/// Per-comic reading progress (resume point + total), persisted in UserDefaults keyed by the
/// comic's filename: the counterpart to Android's Room-backed resume (page *and* panel).
struct Progress: Codable, Equatable {
    var page: Int
    var step: Int      // -1 = whole page, else panel index
    var total: Int     // page count, for the library progress readout
    // Reading direction for THIS comic. Optional so older saved data (which lacked the field)
    // still decodes; nil means "never chosen for this comic" → fall back to the global default.
    var rtl: Bool?
}

enum ReadingProgress {
    private static let key = "chika.progress.v1"
    private static let openedKey = "chika.lastOpened.v1"
    // `var` so tests can point it at their own suite instead of the real app settings.
    static var defaults = UserDefaults.standard

    /// Every comic's progress keyed by filename. Decode once and look up many (the library cards).
    static func all() -> [String: Progress] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Progress].self, from: data) else { return [:] }
        return map
    }

    private static func save(_ map: [String: Progress]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: key) }
    }

    static func get(_ url: URL) -> Progress? { all()[url.lastPathComponent] }

    /// Effective reading direction for a comic: its saved choice if any, else the global default.
    static func readingDirection(_ url: URL, default fallback: Bool) -> Bool { get(url)?.rtl ?? fallback }

    static func set(_ url: URL, page: Int, step: Int, total: Int, rtl: Bool) {
        var map = all()
        map[url.lastPathComponent] = Progress(page: page, step: step, total: total, rtl: rtl)
        save(map)
    }

    static func clear(_ url: URL) {
        var map = all()
        map.removeValue(forKey: url.lastPathComponent)
        save(map)
        var opened = openedMap()
        opened.removeValue(forKey: url.lastPathComponent)
        saveOpened(opened)
    }

    // MARK: - Recency (most-recently-opened ordering, matching Android's `ORDER BY lastOpened DESC`)

    /// Records that a comic was just opened/imported, so the library can order by recency.
    static func markOpened(_ url: URL) {
        var opened = openedMap()
        opened[url.lastPathComponent] = Date().timeIntervalSince1970
        saveOpened(opened)
    }

    /// Last-opened timestamps keyed by filename (missing = never opened), the library sort key.
    /// Decode once per sort, never per comparison.
    static func openedMap() -> [String: Double] {
        guard let data = defaults.data(forKey: openedKey),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return map
    }

    private static func saveOpened(_ map: [String: Double]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: openedKey) }
    }
}
