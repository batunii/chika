import Foundation

/// Per-comic reading progress (resume point + total), persisted in UserDefaults keyed by the
/// comic's filename — the iOS counterpart to Android's Room-backed resume (page *and* panel).
struct Progress: Codable, Equatable {
    var page: Int
    var step: Int      // -1 = whole page, else panel index
    var total: Int     // page count, for the library progress readout
    // Reading direction for THIS comic. Optional so older saved data (which lacked the field)
    // still decodes; nil means "never chosen for this comic" → fall back to the global default.
    var rtl: Bool?

    var fraction: Double { total > 1 ? Double(page) / Double(total - 1) : 0 }
    var percent: Int { Int((fraction * 100).rounded()) }
}

/// App-wide reading preferences. The default reading direction is applied to any comic the user
/// hasn't explicitly toggled yet — the global half of "remembered per comic + a global default",
/// matching Android's behaviour.
enum ReadingPrefs {
    private static let directionKey = "chika.readingDirection.default.rtl"
    private static let fillKey = "chika.zoomFill"
    private static let defaults = UserDefaults.standard

    static var defaultRightToLeft: Bool {
        get { defaults.bool(forKey: directionKey) }
        set { defaults.set(newValue, forKey: directionKey) }
    }

    /// How tightly a framed panel fills the screen (1.0 = edge-to-edge, lower = more padding).
    /// 0.98 is the cross-platform default; the reader lets the user cycle this for taste.
    static let fillLevels: [Float] = [0.86, 0.92, 0.98, 1.0]
    static var zoomFill: Float {
        get { let v = defaults.float(forKey: fillKey); return v == 0 ? 0.98 : v }
        set { defaults.set(newValue, forKey: fillKey) }
    }
}

enum ReadingProgress {
    private static let key = "chika.progress.v1"
    private static let openedKey = "chika.lastOpened.v1"
    private static let defaults = UserDefaults.standard

    private static func load() -> [String: Progress] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Progress].self, from: data) else { return [:] }
        return map
    }

    private static func save(_ map: [String: Progress]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: key) }
    }

    static func get(_ url: URL) -> Progress? { load()[url.lastPathComponent] }

    /// Effective reading direction for a comic: its saved choice if any, else the global default.
    static func readingDirection(_ url: URL) -> Bool { get(url)?.rtl ?? ReadingPrefs.defaultRightToLeft }

    static func set(_ url: URL, page: Int, step: Int, total: Int, rtl: Bool) {
        var map = load()
        map[url.lastPathComponent] = Progress(page: page, step: step, total: total, rtl: rtl)
        save(map)
    }

    static func clear(_ url: URL) {
        var map = load()
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

    /// Last-opened timestamp for a comic (0 if never opened) — the library sort key.
    static func openedAt(_ url: URL) -> Double { openedMap()[url.lastPathComponent] ?? 0 }

    private static func openedMap() -> [String: Double] {
        guard let data = defaults.data(forKey: openedKey),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return map
    }

    private static func saveOpened(_ map: [String: Double]) {
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: openedKey) }
    }
}
