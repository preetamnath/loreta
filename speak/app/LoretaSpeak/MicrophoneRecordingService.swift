import AVFoundation
import Foundation

struct RecordedAudioClip {
    let id: UUID
    let temporaryURL: URL
    let startedAt: Date
    let stoppedAt: Date?
    let duration: TimeInterval

    var isComplete: Bool {
        stoppedAt != nil
    }

    func completed(stoppedAt: Date, duration: TimeInterval) -> RecordedAudioClip {
        RecordedAudioClip(
            id: id,
            temporaryURL: temporaryURL,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            duration: duration
        )
    }
}

enum MicrophoneRecordingError: LocalizedError {
    case permissionDenied
    case recorderStartFailed
    case noActiveRecording
    case missingRecordedFile(URL)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is required before Loreta Speak can start recording. Allow it in System Settings > Privacy & Security > Microphone."
        case .recorderStartFailed:
            "Loreta Speak could not start microphone recording."
        case .noActiveRecording:
            "There is no active microphone recording to stop."
        case .missingRecordedFile(let url):
            "Loreta Speak stopped recording, but the audio file was not found at \(url.path)."
        }
    }
}

@MainActor
final class MicrophoneRecordingService: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var activeClip: RecordedAudioClip?

    func start() async throws -> RecordedAudioClip {
        try await requestMicrophoneAccess()

        let clipID = UUID()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoretaSpeak-\(clipID.uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let audioRecorder = try AVAudioRecorder(url: temporaryURL, settings: settings)
        audioRecorder.delegate = self
        audioRecorder.isMeteringEnabled = true
        audioRecorder.prepareToRecord()

        guard audioRecorder.record() else {
            throw MicrophoneRecordingError.recorderStartFailed
        }

        let clip = RecordedAudioClip(
            id: clipID,
            temporaryURL: temporaryURL,
            startedAt: Date(),
            stoppedAt: nil,
            duration: 0
        )

        recorder = audioRecorder
        activeClip = clip
        return clip
    }

    var elapsedRecordingTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    var normalizedPowerLevel: Double {
        guard let recorder else { return 0 }

        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        let clampedPower = max(-55, min(0, averagePower))
        let linearPower = pow(10, clampedPower / 20)
        return Double(min(1, max(0, linearPower * 5)))
    }

    func stop() throws -> RecordedAudioClip {
        guard let recorder, let activeClip else {
            throw MicrophoneRecordingError.noActiveRecording
        }

        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.activeClip = nil

        guard FileManager.default.fileExists(atPath: activeClip.temporaryURL.path) else {
            throw MicrophoneRecordingError.missingRecordedFile(activeClip.temporaryURL)
        }

        return activeClip.completed(stoppedAt: Date(), duration: duration)
    }

    func cancel() throws {
        guard let recorder, let activeClip else {
            throw MicrophoneRecordingError.noActiveRecording
        }

        recorder.stop()
        self.recorder = nil
        self.activeClip = nil

        try? FileManager.default.removeItem(at: activeClip.temporaryURL)
    }

    private func requestMicrophoneAccess() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)

        guard granted else {
            throw MicrophoneRecordingError.permissionDenied
        }
    }
}
