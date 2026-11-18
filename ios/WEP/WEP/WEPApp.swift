import SwiftUI
import UIKit

final class WEPAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            NotificationManager.shared.configure()
            BackgroundManager.shared.registerTasks { false }
        }
        return true
    }
}

@main
struct WEPApp: App {
    @UIApplicationDelegateAdaptor(WEPAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainShellView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .task {
                    await NotificationManager.shared.requestAuthorizationIfNeeded()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            appState.handleScenePhaseChange(newPhase)
        }
    }
}
