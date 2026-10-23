import SwiftUI

@main
struct ChikaApp: App {
    @StateObject private var settings = ChikaSettings()
    @StateObject private var readers = ReaderModels()
    // App-wide: one set of bookmarks and one folder watcher, shared by every window.
    @StateObject private var library = LibraryStore(keepsSession: !LibraryStore.hostingTests)

    var body: some Scene {
        WindowGroup("Chika", id: "library") { LibraryView().environmentObject(settings).environmentObject(readers).environmentObject(library) }
            .defaultSize(width: 1000, height: 740)
            // Opened files and folders go to the open library window (LibraryView prefers them);
            // only this group may make a window for one, and only when no library window is open.
            .handlesExternalEvents(matching: ["*"])
            .commands { ChikaCommands(library: library, settings: settings) }
        WindowGroup("Reader", id: "reader", for: URL.self) { $url in
            if let url { ReaderView(comicURL: url).environmentObject(settings).environmentObject(readers).environmentObject(library) }
        }
        .defaultSize(width: 820, height: 900)   // portrait, for pages; the system fits it to the screen
        .handlesExternalEvents(matching: [])
        // LibraryStore reopens the readers open at quit itself, whatever the system's "close windows when
        // quitting" setting, and never one whose comic is gone; SwiftUI's restoration would do neither.
        .restorationBehavior(.disabled)
        .commandsRemoved()   // File > New would open a reader with no comic
        WindowGroup("Peek", id: "peek", for: URL.self) { $url in
            if let url { PeekView(comicURL: url).environmentObject(settings).environmentObject(readers) }
        }
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)   // titled underneath so it takes keys; the chrome is hidden in PeekView
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .commandsRemoved()   // File > New would open an empty, invisible peek that takes the keys
        Settings { SettingsView().environmentObject(settings) }
    }
}

extension FocusedValues {
    /// The key library window's file picker, for File > Import Comics… and Add in Place….
    @Entry var libraryPicker: ((LibraryView.PickMode) -> Void)?
    /// The key reader window's commands, for the Reader menu.
    @Entry var reader: ReaderCommands?
}

/// What the Reader menu acts on: the key reader's model and its view's own actions.
struct ReaderCommands {
    let model: ReaderModel
    let wholePage, translate, readAloud, peek, editPanels, exportPanel: () -> Void
}

/// The menu bar: one library window, its file pickers, the reader's commands (so their shortcuts show
/// and can be found) and help.
struct ChikaCommands: Commands {
    let library: LibraryStore
    let settings: ChikaSettings
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.libraryPicker) private var picker
    @FocusedValue(\.reader) private var reader

    var body: some Commands {
        // The app assumes one library window: ⌘N brings it forward, or opens it once closed.
        CommandGroup(replacing: .newItem) {
            Button("Show Library") {
                if let window = LibraryView.window.value, window.isVisible || window.isMiniaturized {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "library")
                }
            }
            .keyboardShortcut("n")
            Divider()
            Button("Import Comics…") { picker?(.importCopies) }
                .keyboardShortcut("o")
                .disabled(picker == nil)
            Button("Add in Place…") { picker?(.inPlace) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(picker == nil)
        }
        CommandGroup(after: .importExport) {
            Button("Export Panel Corrections…") { TrainingExport.run(library: library) }
                .help("Save the pages whose panels you corrected as training data for the panel detector")
                .accessibilityLabel("Export panel corrections as training data")
        }
        CommandMenu("Reader") {
            Group {
                ForEach(Array(ReadingMode.allCases.enumerated()), id: \.element) { i, mode in
                    Button(mode.title) { reader?.model.setMode(mode) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Button("Whole Page") { reader?.wholePage() }
                    .keyboardShortcut("0")
                    .disabled(reader?.model.mode != .panels)
                Divider()
                Button("Previous Page") { reader?.model.turnPage(next: false) }
                    .keyboardShortcut("[")
                Button("Next Page") { reader?.model.turnPage(next: true) }
                    .keyboardShortcut("]")
                Divider()
                Button(reader?.model.marksHere.isEmpty == false ? "Remove Bookmark" : "Add Bookmark") { reader?.model.toggleBookmark() }
                    .keyboardShortcut("d")
                Button("Next Night Filter") { settings.nightFilter = settings.nightFilter.next }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                // Scroll has neither.
                Button("Translate") { reader?.translate() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(reader?.model.mode == .scroll)
                Button("Read Aloud") { reader?.readAloud() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(reader?.model.mode == .scroll)
                Button("Peek") { reader?.peek() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                // Always on: from another mode it switches to Panels, and while panels load it says so.
                Button("Edit Panels") { reader?.editPanels() }
                    .keyboardShortcut("e")
                Button("Export Panel…") { reader?.exportPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            .disabled(reader == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Chika Help") { NSWorkspace.shared.open(URL(string: "https://github.com/batunii/chika#readme")!) }
                .keyboardShortcut("?")
        }
    }
}
