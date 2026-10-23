import SwiftUI

/// Night filters for reading late, applied to page pixels only (never the chrome): inverted colours
/// with hues kept, warm monochrome, or dimming (around the current panel in Panels mode).
enum NightFilter: String, CaseIterable {
    case off, invert, sepia, dim
    var title: String { rawValue.capitalized }
    /// The next filter, wrapping round (the reader's ⌥⌘N).
    var next: NightFilter { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

/// App-wide UI settings, persisted in UserDefaults: the Mac counterpart to Android's AppSettings.
/// The AMOLED theme toggle collapses the ink grounds to true black while the brand accents
/// (crimson/ochre/cream) carry through unchanged (matching Android's ChikaAmoledColorScheme).
@MainActor
final class ChikaSettings: ObservableObject {
    private static let amoledKey = "chika.amoledTheme"
    private static let directionKey = "chika.readingDirection.default.rtl"
    private static let nightFilterKey = "chika.nightFilter"
    private static let translationTargetKey = "chika.translationTarget"
    private let defaults = UserDefaults.standard

    @Published var amoled: Bool {
        didSet { defaults.set(amoled, forKey: Self.amoledKey) }
    }

    /// Reading direction for comics the user hasn't toggled yet; each comic remembers its own once
    /// opened (the global half of "remembered per comic + a global default", as on Android).
    @Published var defaultRightToLeft: Bool {
        didSet { defaults.set(defaultRightToLeft, forKey: Self.directionKey) }
    }

    /// App-wide, not per comic: it suits the hour, not the book.
    @Published var nightFilter: NightFilter {
        didSet { defaults.set(nightFilter.rawValue, forKey: Self.nightFilterKey) }
    }

    /// The language Translate writes in, a BCP 47 identifier; empty = the system language.
    @Published var translationTarget: String {
        didSet { defaults.set(translationTarget, forKey: Self.translationTargetKey) }
    }

    var targetLanguage: Locale.Language {
        translationTarget.isEmpty ? Locale.current.language : Locale.Language(identifier: translationTarget)
    }

    init() {
        amoled = defaults.bool(forKey: Self.amoledKey)
        defaultRightToLeft = defaults.bool(forKey: Self.directionKey)
        nightFilter = defaults.string(forKey: Self.nightFilterKey).flatMap(NightFilter.init(rawValue:)) ?? .off
        translationTarget = defaults.string(forKey: Self.translationTargetKey) ?? ""
    }

    /// Full-screen ground: true black in AMOLED, brand ink otherwise.
    var ground: Color { amoled ? .black : Chika.ink }

    /// Soft raised surface (rows, chips): near-black in AMOLED, brand ink-soft otherwise.
    var groundSoft: Color { amoled ? Color(hex: 0x101010) : Chika.inkSoft }
}
