import SwiftUI

@main
struct ChikaApp: App {
    @StateObject private var settings = ChikaSettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(settings)
        }
    }
}
