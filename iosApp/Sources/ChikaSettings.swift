import SwiftUI

/// App-wide UI settings, persisted in UserDefaults — the iOS counterpart to Android's AppSettings.
/// Currently the AMOLED theme toggle: when on, the ink grounds collapse to true black so OLED
/// pixels switch fully off, while the brand accents (crimson/ochre/cream) carry through unchanged
/// (matching Android's ChikaAmoledColorScheme).
final class ChikaSettings: ObservableObject {
    private static let amoledKey = "chika.amoledTheme"
    private let defaults = UserDefaults.standard

    @Published var amoled: Bool {
        didSet { defaults.set(amoled, forKey: Self.amoledKey) }
    }

    init() {
        amoled = defaults.bool(forKey: Self.amoledKey)
    }

    /// Full-screen ground: true black in AMOLED, brand ink otherwise.
    var ground: Color { amoled ? .black : Chika.ink }

    /// Soft raised surface (rows, chips): near-black in AMOLED, brand ink-soft otherwise.
    var groundSoft: Color { amoled ? Color(hex: 0x101010) : Chika.inkSoft }
}
