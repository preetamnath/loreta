import Foundation

enum DictationPhase: Equatable {
    case idle
    case recording
    case processing(DictationProcessingStep)
    case status(DictationStatusEvent)

    var isRecording: Bool {
        if case .recording = self {
            return true
        }

        return false
    }

    var dismissDelay: Duration? {
        switch self {
        case .idle, .recording, .processing:
            return nil
        case .status(let event):
            return event.dismissDelay
        }
    }
}

enum DictationProcessingStep: Equatable {
    case transcribing
    case transforming
    case pastingLastTranscript
}

enum DictationStatusEvent: Equatable {
    case recordingCancelled(detail: String?)
    case cancelFailed(detail: String)
    case microphoneUnavailable(detail: String)
    case historySaveFailed(detail: String)
    case stopFailed(detail: String)
    case transcriptionFailed(detail: String)
    case transcriptInserted(detail: String?)
    case insertionFailed(detail: String)
    case lastTranscriptInserted
    case noTranscriptToPaste
    case pasteFailed(detail: String)

    var dismissDelay: Duration {
        switch self {
        case .recordingCancelled:
            return .seconds(1.1)
        case .lastTranscriptInserted,
             .noTranscriptToPaste:
            return .seconds(1.2)
        case .transcriptInserted:
            return .milliseconds(650)
        case .cancelFailed,
             .microphoneUnavailable,
             .historySaveFailed,
             .stopFailed,
             .transcriptionFailed,
             .insertionFailed,
             .pasteFailed:
            return .seconds(3)
        }
    }
}
