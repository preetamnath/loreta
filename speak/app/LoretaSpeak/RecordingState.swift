import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class RecordingState: ObservableObject {
    private static let logger = Logger(subsystem: "com.loreta.speak", category: "RecordingState")

    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var lastCompletedRecording: RecordedAudioClip?
    @Published private(set) var lastHistoryItem: LocalHistoryItem?
    @Published private(set) var lastRawTranscriptText: String?
    @Published private(set) var lastTranscriptText: String?
    @Published private(set) var elapsedRecordingSeconds: TimeInterval = 0
    @Published private(set) var audioLevel: Double = 0

    private let recorder: MicrophoneRecordingService
    private let historyStore: LocalHistoryStore
    private let transcriber: LocalSpeechTranscriptionService
    private let insertionService: TextInsertionService
    private let llmService: LLMTransformationService
    private let outputSuppressionService: SystemOutputSuppressionService
    private let settingsStore: SettingsStore
    private var isHandlingToggle = false
    private var statusPanelDismissTask: Task<Void, Never>?
    private var recordingMeterTask: Task<Void, Never>?

    var isRecording: Bool {
        phase.isRecording
    }

    var panelPresentation: RecordingPanelPresentation {
        RecordingPanelPresenter.makePresentation(
            phase: phase,
            elapsedSeconds: elapsedRecordingSeconds,
            audioLevel: audioLevel
        )
    }

    init(
        recorder: MicrophoneRecordingService = MicrophoneRecordingService(),
        historyStore: LocalHistoryStore = LocalHistoryStore(),
        transcriber: LocalSpeechTranscriptionService = LocalSpeechTranscriptionService(),
        insertionService: TextInsertionService = TextInsertionService(),
        llmService: LLMTransformationService = LLMTransformationService(),
        outputSuppressionService: SystemOutputSuppressionService = SystemOutputSuppressionService(),
        settingsStore: SettingsStore = SettingsStore()
    ) {
        self.recorder = recorder
        self.historyStore = historyStore
        self.transcriber = transcriber
        self.insertionService = insertionService
        self.llmService = llmService
        self.outputSuppressionService = outputSuppressionService
        self.settingsStore = settingsStore
        loadMostRecentTranscript()
    }

    func toggleRecording() async {
        guard !isHandlingToggle else { return }

        isHandlingToggle = true
        defer { isHandlingToggle = false }

        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func finishRecording() async {
        guard !isHandlingToggle, isRecording else { return }

        isHandlingToggle = true
        defer { isHandlingToggle = false }

        await stopRecording()
    }

    func cancelRecording() async {
        guard !isHandlingToggle, isRecording else { return }

        isHandlingToggle = true
        defer { isHandlingToggle = false }

        do {
            Self.logger.info("Canceling microphone recording")
            try recorder.cancel()
            var detail: String?
            do {
                try outputSuppressionService.endSuppression()
            } catch {
                detail = error.localizedDescription
                Self.logger.error("Output restoration after cancel failed: \(error.localizedDescription, privacy: .public)")
            }
            stopRecordingMeter()
            phase = .status(.recordingCancelled(detail: detail))
            lastCompletedRecording = nil
            scheduleStatusPanelDismissal()
        } catch {
            try? outputSuppressionService.endSuppression()
            stopRecordingMeter()
            phase = .status(.cancelFailed(detail: error.localizedDescription))
            scheduleStatusPanelDismissal()
            Self.logger.error("Recording cancel failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func pasteLastTranscription(into target: TextInsertionTarget?) async {
        statusPanelDismissTask?.cancel()

        do {
            guard let transcript = lastTranscriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty else {
                phase = .status(.noTranscriptToPaste)
                Self.logger.info("Paste Last Transcription requested without a saved transcript")
                scheduleStatusPanelDismissal()
                return
            }

            Self.logger.info(
                "Manual paste starting: chars=\(transcript.count), targetPid=\(target?.processID ?? -1), app=\(target?.applicationName ?? "unknown", privacy: .public)"
            )

            try await insertionService.insert(transcript, into: target)
            phase = .idle
            Self.logger.info("Last transcript pasted")
        } catch {
            phase = .status(.pasteFailed(detail: manualPasteFailureDetail(for: error)))
            Self.logger.error("Manual paste of last transcript failed: \(error.localizedDescription, privacy: .public)")
        }

        if !isRecording, phase != .idle {
            scheduleStatusPanelDismissal()
        }
    }

    private func startRecording() async {
        do {
            Self.logger.info("Starting microphone recording")
            let clip = try await recorder.start()
            do {
                try outputSuppressionService.beginSuppression()
            } catch {
                Self.logger.error("Output suppression failed at recording start: \(error.localizedDescription, privacy: .public)")
            }
            phase = .recording
            lastCompletedRecording = clip
            elapsedRecordingSeconds = 0
            audioLevel = 0
            statusPanelDismissTask?.cancel()
            startRecordingMeter()
            Self.logger.info("Microphone recording started")
        } catch {
            stopRecordingMeter()
            phase = .status(.microphoneUnavailable(detail: error.localizedDescription))
            scheduleStatusPanelDismissal()
            Self.logger.error("Microphone recording failed before start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadMostRecentTranscript() {
        do {
            guard let item = try historyStore.mostRecentCompletedItem(),
                  let transcript = historyStore.completedTranscript(from: item) else {
                return
            }

            lastHistoryItem = item
            lastRawTranscriptText = item.rawTranscript
            lastTranscriptText = transcript
            Self.logger.info("Loaded most recent completed transcript from history: \(item.folderURL.path, privacy: .public)")
        } catch {
            Self.logger.error("Could not load most recent completed transcript from history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopRecording() async {
        do {
            Self.logger.info("Stopping microphone recording")
            let clip = try recorder.stop()
            let outputRestoreWarning = endOutputSuppression(
                logContext: "Output restoration after stop failed"
            )
            stopRecordingMeter()
            lastCompletedRecording = clip

            do {
                let item = try historyStore.persistAudioClip(clip)
                lastHistoryItem = item
                phase = .processing(.transcribing)
                Self.logger.info("Recording saved to history: \(item.folderURL.path, privacy: .public)")

                await transcribeAndPersistTranscript(for: item)
                if let outputRestoreWarning {
                    Self.logger.error("Output restoration warning after successful stop: \(outputRestoreWarning, privacy: .public)")
                }
            } catch {
                phase = .status(.historySaveFailed(detail: error.localizedDescription))
                scheduleStatusPanelDismissal()
                Self.logger.error("Recording saved in memory but history write failed: \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            try? outputSuppressionService.endSuppression()
            stopRecordingMeter()
            phase = .status(.stopFailed(detail: error.localizedDescription))
            scheduleStatusPanelDismissal()
            Self.logger.error("Recording stop failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func transcribeAndPersistTranscript(for item: LocalHistoryItem) async {
        phase = .processing(.transcribing)
        Self.logger.info("Transcribing audio: \(item.audioURL.path, privacy: .public)")

        let rawTranscript: String
        do {
            rawTranscript = try await transcriber.transcribe(audioURL: item.audioURL)
        } catch {
            phase = .status(.transcriptionFailed(detail: transcriptionFailureDetail(for: error)))
            scheduleStatusPanelDismissal()
            Self.logger.error("Transcription failed without losing audio: \(error.localizedDescription, privacy: .public)")
            return
        }

        lastRawTranscriptText = rawTranscript

        // Optional LLM transformation pass.
        var llmTranscript: String?
        let finalTranscript: String

        if settingsStore.llmTransformationEnabled {
            phase = .processing(.transforming)
            do {
                let transformed = try await llmService.transform(
                    transcript: rawTranscript,
                    instructions: settingsStore.llmInstructions
                )
                llmTranscript = transformed
                finalTranscript = transformed
                Self.logger.info("LLM transformation succeeded")
            } catch {
                llmTranscript = nil
                finalTranscript = rawTranscript
                Self.logger.error("LLM transformation failed, falling back to raw transcript: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            finalTranscript = rawTranscript
        }

        do {
            let updatedItem = try historyStore.updateTranscripts(
                rawTranscript: rawTranscript,
                llmTranscript: llmTranscript,
                for: item
            )
            lastHistoryItem = updatedItem
            lastTranscriptText = finalTranscript
            Self.logger.info("Transcript persisted to history")
        } catch {
            // History write failed — keep transcript in memory and continue
            // to insertion so the user does not lose their dictation.
            lastTranscriptText = finalTranscript
            Self.logger.error("History metadata write failed but transcript preserved in memory: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try insertionService.insert(finalTranscript)
            phase = .status(.transcriptInserted(detail: nil))
            Self.logger.info("Transcript inserted into focused app")
        } catch {
            phase = .status(.insertionFailed(detail: automaticInsertionFailureDetail(for: error)))
            Self.logger.error("Insertion failed but transcript preserved in history: \(error.localizedDescription, privacy: .public)")
        }
        scheduleStatusPanelDismissal()
    }

    private func startRecordingMeter() {
        recordingMeterTask?.cancel()
        recordingMeterTask = Task { @MainActor in
            while !Task.isCancelled, phase.isRecording {
                elapsedRecordingSeconds = recorder.elapsedRecordingTime
                audioLevel = recorder.normalizedPowerLevel
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stopRecordingMeter() {
        recordingMeterTask?.cancel()
        recordingMeterTask = nil
        audioLevel = 0
    }

    private func scheduleStatusPanelDismissal() {
        statusPanelDismissTask?.cancel()
        guard let delay = phase.dismissDelay else { return }

        statusPanelDismissTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !phase.isRecording else { return }
            phase = .idle
        }
    }

    private func endOutputSuppression(logContext: StaticString) -> String? {
        do {
            try outputSuppressionService.endSuppression()
            return nil
        } catch {
            Self.logger.error("\(logContext, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    private func transcriptionFailureDetail(for error: Error) -> String {
        switch error as? LocalSpeechTranscriptionError {
        case .noSpeechRecognized:
            return "No clear speech was detected. The recording was saved."
        case .analyzerUnavailable:
            return "On-device transcription isn't available on this Mac. The recording was saved."
        case .assetUnavailable:
            return "Speech transcription is still getting ready on this Mac. The recording was saved."
        case .recognitionFailed, .none:
            return "The recording was saved. Try again in a moment."
        }
    }

    private func automaticInsertionFailureDetail(for error: Error) -> String {
        switch error as? TextInsertionError {
        case .accessibilityNotGranted:
            return "Turn on Accessibility for Loreta Speak in System Settings > Privacy & Security > Accessibility."
        case .clipboardWriteFailed, .eventPostFailed, .none:
            return "Your transcript is saved. Try Paste Last Transcription from the menu bar."
        }
    }

    private func manualPasteFailureDetail(for error: Error) -> String {
        switch error as? TextInsertionError {
        case .accessibilityNotGranted:
            return "Turn on Accessibility for Loreta Speak in System Settings > Privacy & Security > Accessibility."
        case .clipboardWriteFailed, .eventPostFailed, .none:
            return "Your last transcript is saved. Try again from the menu bar."
        }
    }
}
