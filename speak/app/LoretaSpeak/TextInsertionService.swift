import AppKit
import ApplicationServices
import Foundation
import OSLog

struct TextInsertionTarget: @unchecked Sendable {
    let processID: pid_t
    let focusedElement: AXUIElement?
    let applicationName: String?
    let focusedElementRole: String?
}

enum TextInsertionError: LocalizedError {
    case accessibilityNotGranted
    case clipboardWriteFailed
    case eventPostFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "Loreta Speak needs Accessibility permission to insert text. Open System Settings → Privacy & Security → Accessibility and enable Loreta Speak."
        case .clipboardWriteFailed:
            "Loreta Speak could not write the transcript to the clipboard."
        case .eventPostFailed:
            "Loreta Speak could not paste the transcript into the focused app."
        }
    }
}

@MainActor
final class TextInsertionService {
    private static let logger = Logger(subsystem: "com.loreta.speak", category: "TextInsertion")

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        // Literal value of `kAXTrustedCheckOptionPrompt`. Used directly because the
        // imported C global is flagged as concurrency-unsafe under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func insert(_ text: String) throws {
        guard !text.isEmpty else { return }

        guard ensureAccessibilityPermission(prompt: false) else {
            throw TextInsertionError.accessibilityNotGranted
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboard(saved, into: pasteboard)
            throw TextInsertionError.clipboardWriteFailed
        }

        do {
            try postCommandV()
        } catch {
            restorePasteboard(saved, into: pasteboard)
            throw error
        }

        // The receiving app owns paste handling and may read the pasteboard
        // after its current event turn, especially when a status menu just
        // closed. Restore only if Loreta's temporary text is still present.
        Task { @MainActor [weak self, text] in
            try? await Task.sleep(for: .seconds(1))
            guard pasteboard.string(forType: .string) == text else { return }
            self?.restorePasteboard(saved, into: pasteboard)
        }
    }

    /// Insert text into the previously focused app after a status menu
    /// selection. The target is used only as a logging anchor and as an
    /// activation safety net when the previous app is no longer the
    /// frontmost process. The actual paste relies on the same Cmd+V
    /// synthesis path that the automatic post-dictation insertion uses.
    func insert(_ text: String, into target: TextInsertionTarget?) async throws {
        guard !text.isEmpty else { return }

        guard ensureAccessibilityPermission(prompt: false) else {
            throw TextInsertionError.accessibilityNotGranted
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboard(saved, into: pasteboard)
            throw TextInsertionError.clipboardWriteFailed
        }

        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        Self.logger.info(
            "Manual pasteboard prepared: chars=\(text.count), changeCount=\(pasteboard.changeCount), targetPid=\(target?.processID ?? -1), app=\(target?.applicationName ?? "unknown", privacy: .public), frontmostPid=\(frontmostPid)"
        )

        if let target,
           target.processID != ProcessInfo.processInfo.processIdentifier,
           target.processID != frontmostPid,
           let application = NSRunningApplication(processIdentifier: target.processID),
           !application.isTerminated {
            let activated = application.activate()
            Self.logger.info("Manual paste target activation nudged: pid=\(target.processID), activated=\(activated)")
            // Give AppKit a turn to deliver the activation before posting Cmd+V.
            try? await Task.sleep(for: .milliseconds(120))
        }

        do {
            try postCommandV()
            Self.logger.info("Manual paste posted Cmd+V via cghidEventTap")
        } catch {
            restorePasteboard(saved, into: pasteboard)
            throw error
        }

        Task { @MainActor [weak self, text] in
            try? await Task.sleep(for: .seconds(1))
            guard pasteboard.string(forType: .string) == text else { return }
            self?.restorePasteboard(saved, into: pasteboard)
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restorePasteboard(_ items: [NSPasteboardItem], into pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextInsertionError.eventPostFailed
        }

        let vKeyCode: CGKeyCode = 9 // ANSI 'V'

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            throw TextInsertionError.eventPostFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
