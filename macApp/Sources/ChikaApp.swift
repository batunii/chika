import SwiftUI

@main
struct ChikaApp: App {
    @StateObject private var settings = ChikaSettings()
    @StateObject private var readers = ReaderModels()
    // App-wide: one set of bookmarks and one folder watcher, shared by every window.
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup("Chika") { LibraryView().environmentObject(settings).environmentObject(readers).environmentObject(library) }
            .defaultSize(width: 1000, height: 740)
            // Opened files and folders go to the open library window (LibraryView prefers them);
            // only this group may make a window for one, and only when no library window is open.
            .handlesExternalEvents(matching: ["*"])
            .commands {
                CommandGroup(after: .importExport) {
                    Button("Export Panel Corrections…") { TrainingExport.run(library: library) }
                        .help("Save the pages whose panels you corrected as training data for the panel detector")
                        .accessibilityLabel("Export panel corrections as training data")
                }
            }
        WindowGroup("Reader", id: "reader", for: URL.self) { $url in
            if let url { ReaderView(comicURL: url).environmentObject(settings).environmentObject(readers).environmentObject(library) }
        }
        .handlesExternalEvents(matching: [])
        // LibraryStore reopens the readers open at quit itself, whatever the system's "close windows when
        // quitting" setting, and never one whose comic is gone; SwiftUI's restoration would do neither.
        .restorationBehavior(.disabled)
        WindowGroup("Peek", id: "peek", for: URL.self) { $url in
            if let url { PeekView(comicURL: url).environmentObject(settings).environmentObject(readers) }
        }
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)   // titled underneath so it takes keys; the chrome is hidden in PeekView
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        Settings { SettingsView().environmentObject(settings) }
    }
}
