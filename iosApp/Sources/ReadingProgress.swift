import Foundation

/// Per-comic reading progress (resume point + total), persisted in UserDefaults keyed by the
/// comic's filename — the iOS counterpart to Android's Room-backed resume (page *and* panel).
struct Progress: Codable, Equatable {
    var page: Int
    var step: Int      // -1 = whole page, else panel index
    var total: Int     // page count, for the library progress readout

    var fraction: Double { total > 1 ? Double(page) / Double(total - 1) : 0 }
    var percent: Int { Int((fraction * 100).rounded()) }
}

enum ReadingProgress {
    private static let key = "chika.progress.v1"
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

    static func set(_ url: URL, page: Int, step: Int, total: Int) {
        var map = load()
        map[url.lastPathComponent] = Progress(page: page, step: step, total: total)
        save(map)
    }

    static func clear(_ url: URL) {
        var map = load()
        map.removeValue(forKey: url.lastPathComponent)
        save(map)
    }
}
