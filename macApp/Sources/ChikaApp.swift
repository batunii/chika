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
        WindowGroup("Reader", id: "reader", for: URL.self) { $url in
            if let url { ReaderView(comicURL: url).environmentObject(settings).environmentObject(readers).environmentObject(library) }
        }
        WindowGroup("Peek", id: "peek", for: URL.self) { $url in
            if let url { PeekView(comicURL: url).environmentObject(settings).environmentObject(readers) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        Settings { SettingsView().environmentObject(settings) }
    }
}
