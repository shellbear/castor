import SwiftUI
import CastorEngine

@main
struct CastorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Castor", systemImage: "play.tv") {
            MenuContent()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
