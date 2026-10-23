import AppIntents
import SwiftUI

/// What the Shortcuts actions act on: the reader window last in front, the library, and a way to open
/// and close windows. App Intents run in the app but outside any view, so the windows hand these over
/// as they appear.
@MainActor
enum ShortcutTarget {
    /// One entry per open reader or peek window, the one last in front at the end. Tracked by the windows
    /// rather than held weakly: pending work can keep a closed comic's model alive.
    private(set) static var shown: [ReaderModel] = []
    static var reader: ReaderModel? { shown.last }
    static weak var library: LibraryStore?
    static var windows: (open: OpenWindowAction, dismiss: DismissWindowAction)?
    /// The comics with a peek window open.
    static var peeks: Set<URL> = []

    static func windowOpened(_ model: ReaderModel) { shown.append(model) }

    static func windowActivated(_ model: ReaderModel) {
        if let i = shown.lastIndex(where: { $0 === model }) { shown.append(shown.remove(at: i)) }
    }

    /// The window in front before this one becomes the target again; none once the last has closed.
    static func windowClosed(_ model: ReaderModel) {
        if let i = shown.lastIndex(where: { $0 === model }) { shown.remove(at: i) }
    }

    static func frontReader() throws -> ReaderModel {
        guard let reader else { throw ShortcutError("No comic is open in Chika.") }
        return reader
    }

    static func windowActions() throws -> (open: OpenWindowAction, dismiss: DismissWindowAction) {
        guard let windows else { throw ShortcutError("Chika has no window open yet.") }
        return windows
    }
}

struct ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
    init(_ message: LocalizedStringResource) { localizedStringResource = message }
}

struct NextPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Panel"
    static let description = IntentDescription("Steps Chika's front reader one panel on (a spread in Two pages, a page in Scroll).")

    @MainActor
    func perform() async throws -> some IntentResult {
        try ShortcutTarget.frontReader().advance(by: 1)
        return .result()
    }
}

struct PreviousPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Panel"
    static let description = IntentDescription("Steps Chika's front reader one panel back (a spread in Two pages, a page in Scroll).")

    @MainActor
    func perform() async throws -> some IntentResult {
        try ShortcutTarget.frontReader().advance(by: -1)
        return .result()
    }
}

struct OpenLastComicIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Last Comic"
    static let description = IntentDescription("Opens the comic you opened last in Chika, where you left off.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Launched by this action, Chika's first window may not be up yet to hand over its openWindow.
        for _ in 0..<30 where ShortcutTarget.windows == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let library = ShortcutTarget.library,
              let url = LibraryStore.lastOpened(library.comics, keys: library.keys, opened: ReadingProgress.openedMap())
        else { throw ShortcutError("Chika has no comic to open.") }
        try ShortcutTarget.windowActions().open(id: "reader", value: url)
        return .result()
    }
}

struct TogglePeekIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Peek"
    static let description = IntentDescription("Opens or closes the floating peek window of Chika's front reader.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let url = try ShortcutTarget.frontReader().comicURL
        let windows = try ShortcutTarget.windowActions()
        if ShortcutTarget.peeks.contains(url) { windows.dismiss(id: "peek", value: url) } else { windows.open(id: "peek", value: url) }
        return .result()
    }
}

/// Lists the actions in Shortcuts and Spotlight, and gives Siri its phrases.
struct ChikaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextPanelIntent(), phrases: ["Next panel in \(.applicationName)"],
                    shortTitle: "Next Panel", systemImageName: "chevron.right")
        AppShortcut(intent: PreviousPanelIntent(), phrases: ["Previous panel in \(.applicationName)"],
                    shortTitle: "Previous Panel", systemImageName: "chevron.left")
        AppShortcut(intent: OpenLastComicIntent(), phrases: ["Open my last comic in \(.applicationName)", "Continue reading in \(.applicationName)"],
                    shortTitle: "Open Last Comic", systemImageName: "book")
        AppShortcut(intent: TogglePeekIntent(), phrases: ["Toggle peek in \(.applicationName)"],
                    shortTitle: "Toggle Peek", systemImageName: "pip")
    }
}
