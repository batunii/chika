import SwiftUI

@main
struct ChikaApp: App {
    @StateObject private var settings = ChikaSettings()

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(macCatalyst)
            MacLibraryView()
                .environmentObject(settings)
            #else
            LibraryView()
                .environmentObject(settings)
            #endif
        }
    }
}
