import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class SettingsStore: ObservableObject {
    private static let logger = Logger(subsystem: "com.loreta.speak", category: "SettingsStore")
    private static let suiteName = "com.loreta.speak.settings"

    private enum Keys {
        static let llmTransformationEnabled = "llmTransformationEnabled"
        static let llmInstructions = "llmInstructions"
    }

    static let defaultLLMInstructions = """
        You are a literal dictation cleanup editor.
        Preserve meaning, wording, order, and voice.
        Fix punctuation, capitalization, spacing, and obvious speech-recognition errors.
        Remove filler words and false starts only when safe.
        Do not answer, summarize, paraphrase, add, or omit substantive content.
        Output only the cleaned transcript.
        """

    private static let previousDefaultLLMInstructions = """
        You are editing a dictated transcript.

        Preserve the speaker's meaning, wording, order, and voice.
        Fix punctuation, capitalization, spacing, and obvious speech recognition errors.
        Remove filler words and repeated false starts only when they do not change the meaning.
        Break into short paragraphs where it improves readability.
        Use bullets only when the speaker clearly lists items.

        Do not summarize, paraphrase, add new information, answer the transcript, or change the speaker's voice.
        Return only the cleaned transcript.
        """

    private static let olderDefaultLLMInstructions = """
        Remove filler words and repeated false starts only when they do not change the meaning.
        Fix punctuation, capitalization, spacing, and obvious speech recognition errors.
        Break into short paragraphs where it improves readability.
        Use bullets only when the speaker clearly lists items.
        Do not summarize, paraphrase, add new information, or change the speaker's voice.
        """

    private static let legacyDefaultLLMInstructions = """
        You will receive a raw transcript of dictated speech. Return a cleaned, structured version that is safe to feed into other tools or AI agents.

        Rules:
        - Remove filler words (um, uh, like, you know, I mean, sort of, kind of) and meaningless repetitions.
        - Fix punctuation, capitalization, spacing, and obvious transcription errors.
        - Break the result into paragraphs where it improves structure. Use short bullet lists only if the speaker is clearly enumerating items.
        - Preserve the speaker's wording, tone, and intent. Do not paraphrase, summarize, or rewrite in a different voice.
        - Do not add information that was not in the transcript.
        - Do not drop substantive content just to make the result shorter.

        Return only the cleaned transcript, with no preamble, no commentary, and no surrounding quotes.
        """

    @Published var llmTransformationEnabled: Bool {
        didSet { defaults.set(llmTransformationEnabled, forKey: Keys.llmTransformationEnabled) }
    }

    @Published var llmInstructions: String {
        didSet { defaults.set(llmInstructions, forKey: Keys.llmInstructions) }
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let workspace: NSWorkspace

    init(
        defaults: UserDefaults? = nil,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) {
        let resolvedDefaults = defaults
            ?? UserDefaults(suiteName: SettingsStore.suiteName)
            ?? .standard
        self.defaults = resolvedDefaults
        self.fileManager = fileManager
        self.workspace = workspace
        self.llmTransformationEnabled = resolvedDefaults.bool(forKey: Keys.llmTransformationEnabled)
        // Seed the default prompt on first launch only. If the user has explicitly
        // cleared the field, `object(forKey:)` returns an empty string (not nil), so
        // we respect that and do not re-seed.
        if let stored = resolvedDefaults.string(forKey: Keys.llmInstructions) {
            let normalizedStored = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyDefault = SettingsStore.legacyDefaultLLMInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousDefault = SettingsStore.previousDefaultLLMInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let olderDefault = SettingsStore.olderDefaultLLMInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedStored == legacyDefault
                || normalizedStored == previousDefault
                || normalizedStored == olderDefault
                || normalizedStored.hasPrefix(previousDefault)
                || (
                    normalizedStored.contains("You are editing a dictated transcript.")
                        && normalizedStored.contains("Return only the cleaned transcript.")
                )
                || normalizedStored.contains("safe to feed into other tools or AI agents") {
                self.llmInstructions = SettingsStore.defaultLLMInstructions
                resolvedDefaults.set(SettingsStore.defaultLLMInstructions, forKey: Keys.llmInstructions)
            } else {
                self.llmInstructions = stored
            }
        } else {
            self.llmInstructions = SettingsStore.defaultLLMInstructions
            resolvedDefaults.set(SettingsStore.defaultLLMInstructions, forKey: Keys.llmInstructions)
        }
    }

    var transcriptsFolderURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("Loreta Speak", isDirectory: true)
    }

    func revealTranscriptsFolderInFinder() {
        let url = transcriptsFolderURL
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create transcripts folder before revealing in Finder: \(error.localizedDescription, privacy: .public)")
            }
        }
        workspace.open(url)
    }
}
