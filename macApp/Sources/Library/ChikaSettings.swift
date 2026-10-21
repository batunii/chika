import SwiftUI

/// App-wide UI settings, persisted in UserDefaults: the Mac counterpart to Android's AppSettings.
/// The AMOLED theme toggle collapses the ink grounds to true black while the brand accents
/// (crimson/ochre/cream) carry through unchanged (matching Android's ChikaAmoledColorScheme).
@MainActor
final class ChikaSettings: ObservableObject {
    private static let amoledKey = "chika.amoledTheme"
    private static let directionKey = "chika.readingDirection.default.rtl"
    private let defaults = UserDefaults.standard

    @Published var amoled: Bool {
        didSet { defaults.set(amoled, forKey: Self.amoledKey) }
    }

    /// Reading direction for comics the user hasn't toggled yet; each comic remembers its own once
    /// opened (the global half of "remembered per comic + a global default", as on Android).
    @Published var defaultRightToLeft: Bool {
        didSet { defaults.set(defaultRightToLeft, forKey: Self.directionKey) }
    }

    init() {
        amoled = defaults.bool(forKey: Self.amoledKey)
        defaultRightToLeft = defaults.bool(forKey: Self.directionKey)
    }

    /// Full-screen ground: true black in AMOLED, brand ink otherwise.
    var ground: Color { amoled ? .black : Chika.ink }

    /// Soft raised surface (rows, chips): near-black in AMOLED, brand ink-soft otherwise.
    var groundSoft: Color { amoled ? Color(hex: 0x101010) : Chika.inkSoft }
}
