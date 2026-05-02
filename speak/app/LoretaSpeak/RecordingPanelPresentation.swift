import CoreGraphics
import Foundation

enum RecordingPanelPresentation: Equatable {
    case hidden
    case recording(RecordingPresentation)
    case status(StatusPresentation)

    var isVisible: Bool {
        if case .hidden = self {
            return false
        }

        return true
    }

    var panelSize: CGSize {
        switch self {
        case .hidden:
            return .zero
        case .recording:
            return CGSize(width: 286, height: 42)
        case .status(let status):
            return status.panelSize
        }
    }
}

struct RecordingPresentation: Equatable {
    let elapsedSeconds: TimeInterval
    let audioLevel: Double
}

struct StatusPresentation: Equatable {
    enum Layout: Equatable {
        case compact
        case recovery
    }

    enum Tone: Equatable {
        case neutral
        case success
        case error
        case processing
    }

    enum Icon: Equatable {
        case cancelled
        case success
        case error
        case processing
    }

    let layout: Layout
    let title: String
    let detail: String?
    let tone: Tone
    let icon: Icon

    var panelSize: CGSize {
        switch layout {
        case .compact:
            return CGSize(width: 286, height: 42)
        case .recovery:
            if hasDetail {
                return CGSize(width: 372, height: 68)
            }

            return CGSize(width: 286, height: 44)
        }
    }

    var hasDetail: Bool {
        guard let detail else { return false }
        return detail.isEmpty == false
    }

    var hasTitle: Bool {
        title.isEmpty == false
    }
}

enum RecordingPanelPresenter {
    static func makePresentation(
        phase: DictationPhase,
        elapsedSeconds: TimeInterval,
        audioLevel: Double
    ) -> RecordingPanelPresentation {
        switch phase {
        case .idle:
            return .hidden
        case .recording:
            return .recording(RecordingPresentation(
                elapsedSeconds: elapsedSeconds,
                audioLevel: audioLevel
            ))
        case .processing(let step):
            return .status(statusPresentation(for: step))
        case .status(let event):
            return .status(statusPresentation(for: event))
        }
    }

    private static func statusPresentation(for step: DictationProcessingStep) -> StatusPresentation {
        let title: String

        switch step {
        case .transcribing:
            title = "Transcribing"
        case .transforming:
            title = "Cleaning up transcript"
        case .pastingLastTranscript:
            title = "Pasting last transcription"
        }

        return StatusPresentation(
            layout: .compact,
            title: title,
            detail: nil,
            tone: .processing,
            icon: .processing
        )
    }

    private static func statusPresentation(for event: DictationStatusEvent) -> StatusPresentation {
        switch event {
        case .recordingCancelled(let detail):
            return StatusPresentation(
                layout: .compact,
                title: "Canceled",
                detail: detail,
                tone: .neutral,
                icon: .cancelled
            )
        case .cancelFailed(let detail):
            return StatusPresentation(
                layout: .recovery,
                title: "Cancel failed",
                detail: detail,
                tone: .error,
                icon: .error
            )
        case .microphoneUnavailable(let detail):
            return StatusPresentation(
                layout: .recovery,
                title: "Microphone unavailable",
                detail: detail,
                tone: .error,
                icon: .error
            )
        case .historySaveFailed(let detail):
            return StatusPresentation(
                layout: .recovery,
                title: "History save failed",
                detail: detail,
                tone: .error,
                icon: .error
            )
        case .stopFailed(let detail):
            return StatusPresentation(
                layout: .recovery,
                title: "Recording stop failed",
                detail: detail,
                tone: .error,
                icon: .error
            )
        case .transcriptionFailed(let detail):
            return StatusPresentation(
                layout: .recovery,
                title: "Transcription failed",
                detail: detail,
                tone: .error,
                icon: .error
            )
        case .transcriptInserted:
            return StatusPresentation(
                layout: .compact,
                title: "",
                detail: nil,
                tone: .success,
                icon: .success
            )
        case .insertionFailed(let detail):
            return StatusPresentation(
                layout: .recovery,
                title: "Couldn't insert text",
                detail: detail,
                tone: .error,
                icon: .error
            )
        case .lastTranscriptInserted:
            return StatusPresentation(
                layout: .compact,
                title: "Last transcription pasted",
                detail: nil,
                tone: .success,
                icon: .success
            )
        case .noTranscriptToPaste:
            return StatusPresentation(
                layout: .compact,
                title: "No transcription yet",
                detail: nil,
                tone: .neutral,
                icon: .cancelled
            )
        case .pasteFailed(let detail):
            return StatusPresentation(
                layout: .recovery,
                title: "Couldn't insert text",
                detail: detail,
                tone: .error,
                icon: .error
            )
        }
    }
}
