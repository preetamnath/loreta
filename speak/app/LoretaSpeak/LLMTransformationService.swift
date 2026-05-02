import Foundation
import FoundationModels
import OSLog

enum LLMTransformationError: LocalizedError {
    case appleIntelligenceUnavailable(reason: String)
    case guardrailViolation(underlying: Error)
    case contextWindowExceeded(underlying: Error)
    case generationFailed(underlying: Error)
    case emptyTranscript
    case unsafeOutput(reason: String)

    var errorDescription: String? {
        switch self {
        case .appleIntelligenceUnavailable(let reason):
            return "Apple Intelligence is not available for transformation: \(reason)"
        case .guardrailViolation:
            return "The on-device model declined to transform this transcript due to content guardrails."
        case .contextWindowExceeded:
            return "The transcript was too long for the on-device model's context window."
        case .generationFailed(let underlying):
            return "On-device LLM transformation failed: \(underlying.localizedDescription)"
        case .emptyTranscript:
            return "Loreta Speak skipped LLM transformation because the raw transcript was empty."
        case .unsafeOutput(let reason):
            return "Loreta Speak skipped LLM transformation because the cleaned transcript looked unsafe to insert: \(reason)"
        }
    }
}

@MainActor
final class LLMTransformationService {
    private static let logger = Logger(subsystem: "com.loreta.speak", category: "LLMTransformationService")

    func transform(transcript: String, instructions: String) async throws -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw LLMTransformationError.emptyTranscript
        }

        try ensureAvailability()
        let session = LanguageModelSession(instructions: Instructions(cleanupInstructions(from: instructions)))
        let prompt = cleanupPrompt(for: trimmedTranscript)
        let options = GenerationOptions(sampling: .greedy, temperature: 0.0)

        do {
            let response = try await session.respond(to: prompt, options: options)
            let cleanedTranscript = sanitizeCleanedTranscript(response.content)
            try validateCleanedTranscript(cleanedTranscript, originalTranscript: trimmedTranscript)
            return cleanedTranscript
        } catch {
            if let transformationError = error as? LLMTransformationError {
                throw transformationError
            }
            // Map known FoundationModels error variants by inspecting the
            // runtime case description; resilient to enum-name shifts across
            // Foundation Models seeds without losing typed dispatch.
            let signature = String(describing: error).lowercased()
            if signature.contains("contextwindow") {
                Self.logger.error("LLM transformation exceeded context window")
                throw LLMTransformationError.contextWindowExceeded(underlying: error)
            }
            if signature.contains("guardrail") {
                Self.logger.error("LLM transformation blocked by guardrails")
                throw LLMTransformationError.guardrailViolation(underlying: error)
            }
            Self.logger.error("LLM transformation failed: \(error.localizedDescription, privacy: .public)")
            throw LLMTransformationError.generationFailed(underlying: error)
        }
    }

    private func ensureAvailability() throws {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return
        case .unavailable(let reason):
            // String(describing:) keeps us decoupled from the exact inner
            // enum identifier shape, which has shifted across Foundation
            // Models seeds.
            let raw = String(describing: reason)
            Self.logger.error("Foundation Models unavailable: \(raw, privacy: .public)")
            throw LLMTransformationError.appleIntelligenceUnavailable(
                reason: humanReadable(unavailableReasonDescription: raw)
            )
        }
    }

    private func humanReadable(unavailableReasonDescription description: String) -> String {
        let lowered = description.lowercased()
        if lowered.contains("appleintelligencenotenabled") {
            return "Apple Intelligence is turned off in System Settings."
        }
        if lowered.contains("devicenoteligible") {
            return "This Mac does not support Apple Intelligence."
        }
        if lowered.contains("modelnotready") {
            return "The on-device model is still downloading. Try again shortly."
        }
        return description
    }

    private func cleanupInstructions(from userInstructions: String) -> String {
        let trimmed = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SettingsStore.defaultLLMInstructions
        }
        return trimmed
    }

    private func cleanupPrompt(for transcript: String) -> Prompt {
        Prompt("""
            Clean this dictated transcript. Output only the cleaned transcript.

            <<<
            \(transcript)
            >>>
            """)
    }

    private func sanitizeCleanedTranscript(_ response: String) -> String {
        var output = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if let extracted = extractTextBetweenTranscriptMarkers(in: output) {
            output = extracted
        }

        output = stripKnownAssistantPreamble(from: output)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateCleanedTranscript(_ cleanedTranscript: String, originalTranscript: String) throws {
        let cleaned = cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw LLMTransformationError.unsafeOutput(reason: "empty output")
        }

        if cleaned.contains("<<<") || cleaned.contains(">>>") {
            throw LLMTransformationError.unsafeOutput(reason: "copied transcript markers")
        }

        let lowered = cleaned.lowercased()
        let assistantResponsePrefixes = [
            "yes,",
            "no,",
            "i can help",
            "i'm sorry",
            "i am sorry",
            "as an llm",
            "as a language model"
        ]
        if assistantResponsePrefixes.contains(where: { lowered.hasPrefix($0) }) {
            throw LLMTransformationError.unsafeOutput(reason: "assistant-style response")
        }

        if originalTranscript.count >= 100 && cleaned.count < Int(Double(originalTranscript.count) * 0.85) {
            throw LLMTransformationError.unsafeOutput(reason: "suspiciously shorter than the raw transcript")
        }
    }

    private func extractTextBetweenTranscriptMarkers(in text: String) -> String? {
        guard
            let start = text.range(of: "<<<"),
            let end = text.range(of: ">>>", range: start.upperBound..<text.endIndex),
            start.upperBound <= end.lowerBound
        else {
            return nil
        }

        return String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripKnownAssistantPreamble(from text: String) -> String {
        let patterns = [
            #"(?i)^sure[,!.\s-]*here is the cleaned transcript[:\s-]*"#,
            #"(?i)^here is the cleaned transcript[:\s-]*"#,
            #"(?i)^cleaned transcript[:\s-]*"#
        ]

        var output = text
        for pattern in patterns {
            if let range = output.range(of: pattern, options: .regularExpression) {
                output.removeSubrange(range)
                break
            }
        }
        return output
    }
}
