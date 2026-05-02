import AVFoundation
import Foundation
import Speech

enum LocalSpeechTranscriptionError: LocalizedError {
    case analyzerUnavailable
    case assetUnavailable
    case noSpeechRecognized
    case recognitionFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .analyzerUnavailable:
            "Apple Speech Analyzer is unavailable on this Mac."
        case .assetUnavailable:
            "Apple Speech Analyzer assets are unavailable for the selected locale."
        case .noSpeechRecognized:
            "Loreta Speak could not recognize speech in the recorded audio."
        case .recognitionFailed(let underlying):
            "Loreta Speak could not transcribe the recorded audio with Apple Speech Analyzer: \(underlying.localizedDescription)"
        }
    }
}

final class LocalSpeechTranscriptionService: @unchecked Sendable {
    private let preferredLocale: Locale

    init(preferredLocale: Locale = Locale(identifier: "en-IN")) {
        self.preferredLocale = preferredLocale
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw LocalSpeechTranscriptionError.analyzerUnavailable
        }

        return try await transcribeUsingSpeechAnalyzer(audioURL: audioURL)
    }

    @available(macOS 26.0, *)
    private func transcribeUsingSpeechAnalyzer(audioURL: URL) async throws -> String {
        if SpeechTranscriber.isAvailable {
            for locale in candidateLocales {
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                if await prepareAssetsForSpeechTranscriber(transcriber, locale: locale) {
                    return try await transcribeWith(transcriber: transcriber, audioURL: audioURL)
                }
            }
        }

        for locale in candidateLocales {
            let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
            if await prepareAssetsForDictationTranscriber(transcriber, locale: locale) {
                return try await transcribeWith(transcriber: transcriber, audioURL: audioURL)
            }
        }

        throw LocalSpeechTranscriptionError.assetUnavailable
    }

    private var candidateLocales: [Locale] {
        [
            preferredLocale,
            Locale.autoupdatingCurrent,
            Locale.current,
            Locale(identifier: "en-US"),
            Locale(identifier: "en-GB")
        ]
    }

    @available(macOS 26.0, *)
    private func transcribeWith(transcriber: SpeechTranscriber, audioURL: URL) async throws -> String {
        return try await transcribeWithAnalyzer(audioURL: audioURL, transcriber: transcriber) { result in
            String(result.text.characters)
        }
    }

    @available(macOS 26.0, *)
    private func transcribeWith(transcriber: DictationTranscriber, audioURL: URL) async throws -> String {
        return try await transcribeWithAnalyzer(audioURL: audioURL, transcriber: transcriber) { result in
            String(result.text.characters)
        }
    }

    @available(macOS 26.0, *)
    private func prepareAssetsForSpeechTranscriber(
        _ transcriber: SpeechTranscriber,
        locale: Locale
    ) async -> Bool {
        await prepareAssetsCommon(
            for: transcriber,
            locale: locale,
            supportedLocales: { await SpeechTranscriber.supportedLocales }
        )
    }

    @available(macOS 26.0, *)
    private func prepareAssetsForDictationTranscriber(
        _ transcriber: DictationTranscriber,
        locale: Locale
    ) async -> Bool {
        await prepareAssetsCommon(
            for: transcriber,
            locale: locale,
            supportedLocales: { await DictationTranscriber.supportedLocales }
        )
    }

    @available(macOS 26.0, *)
    private func prepareAssetsCommon<Module: SpeechModule>(
        for module: Module,
        locale: Locale,
        supportedLocales: @Sendable () async -> [Locale]
    ) async -> Bool where Module: LocaleDependentSpeechModule {
        // 1. Trigger asset install first (idempotent). On a fresh machine
        //    `supportedLocales` is empty until at least one install request fires.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        } catch {
            return false
        }

        // 2. Validate locale support using BCP47 identifiers — `Locale.identifier`
        //    can return `en_US` while the framework canonicalizes to `en-US`.
        let supported = await supportedLocales()
        let target = locale.identifier(.bcp47)
        let isSupported = supported.contains { $0.identifier(.bcp47) == target }
        guard isSupported else { return false }

        // 3. Reserve the locale. Done *after* assets exist and locale is known supported.
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            return false
        }

        return true
    }

    @available(macOS 26.0, *)
    private func transcribeWithAnalyzer<Module: SpeechModule>(
        audioURL: URL,
        transcriber: Module,
        textForResult: @Sendable @escaping (Module.Results.Element) -> String
    ) async throws -> String where Module.Results.Element: SpeechModuleResult {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let transcriptTask = Self.collectTranscript(from: transcriber.results, textForResult: textForResult)

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            throw LocalSpeechTranscriptionError.recognitionFailed(underlying: error)
        }

        let transcript = try await transcriptTask

        guard !transcript.isEmpty else {
            throw LocalSpeechTranscriptionError.noSpeechRecognized
        }

        return transcript
    }

    @available(macOS 26.0, *)
    private static func collectTranscript<ResultSequence: AsyncSequence>(
        from results: ResultSequence,
        textForResult: @Sendable @escaping (ResultSequence.Element) -> String
    ) async throws -> String where ResultSequence.Failure == any Error, ResultSequence.Element: SpeechModuleResult {
        var chunks: [String] = []

        do {
            for try await result in results {
                let text = textForResult(result).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                if result.isFinal {
                    chunks.append(text)
                }
            }
        } catch {
            throw LocalSpeechTranscriptionError.recognitionFailed(underlying: error)
        }

        return chunks.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
