import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class RecordingPanelHost {
    private let recordingState: RecordingState
    private let panel: NSPanel
    private let hostingView: NSHostingView<RecordingPanelView>
    private var cancellables = Set<AnyCancellable>()
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
        self.hostingView = NSHostingView(rootView: RecordingPanelView(recordingState: recordingState))
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 286, height: 42),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        observeRecordingState()
        syncPanel()
    }

    private func observeRecordingState() {
        recordingState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.syncPanel()
                }
            }
            .store(in: &cancellables)
    }

    private func syncPanel() {
        let presentation = recordingState.panelPresentation
        guard presentation.isVisible else {
            removeEscapeMonitors()
            panel.orderOut(nil)
            return
        }

        updatePanelSize(to: presentation.panelSize)
        positionPanel()
        updateEscapeMonitoring()
        panel.orderFrontRegardless()
    }

    private func updatePanelSize(to size: CGSize) {
        guard panel.frame.size != size else { return }

        panel.setContentSize(size)
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - 32
        )

        panel.setFrameOrigin(origin)
    }

    private func updateEscapeMonitoring() {
        if recordingState.isRecording {
            installEscapeMonitorsIfNeeded()
        } else {
            removeEscapeMonitors()
        }
    }

    private func installEscapeMonitorsIfNeeded() {
        if localEscapeMonitor == nil {
            localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.cancelRecordingFromEscape()
                return nil
            }
        }

        if globalEscapeMonitor == nil {
            globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                self?.cancelRecordingFromEscape()
            }
        }
    }

    private func removeEscapeMonitors() {
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }

        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
    }

    private func cancelRecordingFromEscape() {
        guard recordingState.isRecording else { return }
        Task { await recordingState.cancelRecording() }
    }
}
