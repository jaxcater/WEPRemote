import SwiftUI

@main
struct WEPApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainShellView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}
