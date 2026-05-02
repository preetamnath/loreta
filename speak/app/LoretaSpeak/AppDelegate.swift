import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    private var menuBarController: MenuBarController?
    private lazy var recordingState = RecordingState(settingsStore: settingsStore)
    private let insertionService = TextInsertionService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(
            recordingState: recordingState,
            settingsStore: settingsStore
        )
        // Surface the Accessibility permission dialog up front so the first
        // dictation insertion does not silently fail. Re-prompt only if not
        // yet trusted; AXIsProcessTrustedWithOptions is a no-op when granted.
        if !insertionService.isAccessibilityTrusted {
            _ = insertionService.ensureAccessibilityPermission(prompt: true)
        }
    }
}
