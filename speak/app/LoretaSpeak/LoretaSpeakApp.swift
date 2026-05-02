import SwiftUI

@main
struct LoretaSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settingsStore: appDelegate.settingsStore)
        }
    }
}
