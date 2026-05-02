import AppKit
import ApplicationServices
import Combine
import OSLog
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private static let logger = Logger(subsystem: "com.loreta.speak", category: "MenuBar")

    private let recordingState: RecordingState
    private let statusItem: NSStatusItem
    private let statusMenu: NSMenu
    private let recordingPanelHost: RecordingPanelHost
    private let settingsWindowController: NSWindowController
    private let workspace: NSWorkspace
    private var hotKeyService: GlobalHotKeyService?
    private var cancellables = Set<AnyCancellable>()
    private var capturedPasteTarget: TextInsertionTarget?
    private var lastNonLoretaForegroundProcessID: pid_t?

    init(
        recordingState: RecordingState,
        settingsStore: SettingsStore,
        workspace: NSWorkspace = .shared
    ) {
        self.recordingState = recordingState
        self.workspace = workspace
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = NSMenu()
        recordingPanelHost = RecordingPanelHost(recordingState: recordingState)
        settingsWindowController = MenuBarController.makeSettingsWindowController(settingsStore: settingsStore)

        super.init()

        hotKeyService = GlobalHotKeyService { [weak self] in
            self?.toggleRecordingState()
        }

        configureStatusItem()
        observeForegroundApplications()
        startHotKeyService()
    }

    private func configureStatusItem() {
        statusItem.button?.title = "Loreta"
        statusItem.button?.toolTip = "Loreta Speak"

        let menu = statusMenu
        menu.delegate = self
        menu.autoenablesItems = true

        let pasteItem = NSMenuItem(
            title: "Paste Last Transcription",
            action: #selector(pasteLastTranscription),
            keyEquivalent: "v"
        )
        pasteItem.keyEquivalentModifierMask = [.command]
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Toggle Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        ))
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Loreta Speak",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func toggleRecording() {
        toggleRecordingState()
    }

    @objc private func pasteLastTranscription() {
        let target = capturedPasteTarget
        if let target {
            Self.logger.info(
                "Paste Last Transcription menu action fired: targetPid=\(target.processID), app=\(target.applicationName ?? "unknown", privacy: .public)"
            )
        } else {
            Self.logger.info("Paste Last Transcription menu action fired without captured target; will paste into whatever has key focus")
        }

        capturedPasteTarget = nil

        // Trigger the paste from the action selector itself rather than
        // from `menuDidClose`, because AppKit's ordering of action vs.
        // menuDidClose with a status menu cannot be relied on to leave
        // any inter-callback state intact.
        //
        // The brief delay lets the status menu fully dismiss and gives
        // the previously focused app a runloop turn to reclaim key
        // event delivery before we synthesize Cmd+V.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.recordingState.pasteLastTranscription(into: target)
        }
    }

    private func toggleRecordingState() {
        Task { @MainActor in
            await recordingState.toggleRecording()
        }
    }

    private func startHotKeyService() {
        do {
            try hotKeyService?.start()
        } catch {
            assertionFailure(error.localizedDescription)
        }
    }

    @objc private func showSettings() {
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func observeForegroundApplications() {
        workspace.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard
                    let self,
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    !self.isLoretaSpeakApplication(application)
                else {
                    return
                }

                self.lastNonLoretaForegroundProcessID = application.processIdentifier
            }
            .store(in: &cancellables)
    }

    private func currentPasteTarget() -> TextInsertionTarget? {
        if let focusedTarget = focusedElementTarget(),
           !isLoretaSpeakProcess(focusedTarget.processID) {
            return focusedTarget
        }

        if let frontmostApplication = workspace.frontmostApplication,
           !isLoretaSpeakApplication(frontmostApplication) {
            return TextInsertionTarget(
                processID: frontmostApplication.processIdentifier,
                focusedElement: nil,
                applicationName: frontmostApplication.localizedName,
                focusedElementRole: nil
            )
        }

        if let lastNonLoretaForegroundProcessID,
           let application = NSRunningApplication(processIdentifier: lastNonLoretaForegroundProcessID),
           application.isTerminated == false {
            return TextInsertionTarget(
                processID: lastNonLoretaForegroundProcessID,
                focusedElement: nil,
                applicationName: application.localizedName,
                focusedElementRole: nil
            )
        }

        return nil
    }

    private func captureCurrentPasteTarget() {
        capturedPasteTarget = currentPasteTarget()
        if let capturedPasteTarget {
            lastNonLoretaForegroundProcessID = capturedPasteTarget.processID
            Self.logger.info(
                "Captured paste target before menu: targetPid=\(capturedPasteTarget.processID), app=\(capturedPasteTarget.applicationName ?? "unknown", privacy: .public), focusedRole=\(capturedPasteTarget.focusedElementRole ?? "none", privacy: .public)"
            )
        } else {
            Self.logger.error("Could not capture paste target before menu")
        }
    }

    private func isLoretaSpeakApplication(_ application: NSRunningApplication) -> Bool {
        isLoretaSpeakProcess(application.processIdentifier)
    }

    private func isLoretaSpeakProcess(_ processID: pid_t) -> Bool {
        processID == ProcessInfo.processInfo.processIdentifier
    }

    private func focusedElementTarget() -> TextInsertionTarget? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusedElementError = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementError == .success,
              let focusedElement = focusedElementValue else {
            return nil
        }

        var processID: pid_t = 0
        let focusedAXElement = focusedElement as! AXUIElement
        let processIDError = AXUIElementGetPid(focusedAXElement, &processID)
        guard processIDError == .success else {
            return nil
        }

        let application = NSRunningApplication(processIdentifier: processID)
        return TextInsertionTarget(
            processID: processID,
            focusedElement: focusedAXElement,
            applicationName: application?.localizedName,
            focusedElementRole: stringAttribute(kAXRoleAttribute, from: focusedAXElement)
        )
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    func menuWillOpen(_ menu: NSMenu) {
        // System-wide AX focus is already gone by the time AppKit calls
        // `menuWillOpen`, so we cannot rely on it for the focused element.
        // We still record the frontmost / last-active app PID for diagnostics
        // and as a fallback target if Cmd+V routing ever needs an activation
        // nudge.
        captureCurrentPasteTarget()
    }

    func menuDidClose(_ menu: NSMenu) {
        // Intentionally a no-op. The paste is dispatched directly from the
        // menu item's action selector to avoid relying on AppKit's ordering
        // of action vs. menuDidClose (which is not stable enough to use as
        // a state hand-off mechanism).
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(pasteLastTranscription):
            if let transcript = recordingState.lastTranscriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !transcript.isEmpty {
                return true
            }

            return false
        default:
            return true
        }
    }

    private static func makeSettingsWindowController(settingsStore: SettingsStore) -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Loreta Speak Settings"
        window.contentView = NSHostingView(rootView: SettingsView(settingsStore: settingsStore))
        window.isReleasedWhenClosed = false

        return NSWindowController(window: window)
    }
}
