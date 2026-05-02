import Foundation

struct LocalHistoryItem: Codable {
    let id: UUID
    let createdAt: Date
    let durationSeconds: TimeInterval
    let audioFileName: String
    /// Direct output of the local speech transcriber. `nil` until
    /// transcription finishes.
    let rawTranscript: String?
    /// Foundation Models output. `nil` when the LLM toggle is off or the
    /// transformation failed.
    let llmTranscript: String?
    let folderURL: URL
    let audioURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case durationSeconds
        case audioFileName
        case rawTranscript
        case llmTranscript
    }

    init(
        id: UUID,
        createdAt: Date,
        durationSeconds: TimeInterval,
        audioFileName: String,
        rawTranscript: String?,
        llmTranscript: String?,
        folderURL: URL,
        audioURL: URL
    ) {
        self.id = id
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.audioFileName = audioFileName
        self.rawTranscript = rawTranscript
        self.llmTranscript = llmTranscript
        self.folderURL = folderURL
        self.audioURL = audioURL
    }

    init(from decoder: Decoder) throws {
        // `LocalHistoryItem` is encoded for the on-disk metadata.json shape
        // only; folderURL/audioURL are derived from disk layout, not stored.
        // Decoding is therefore not used in v1, but a Codable-correct
        // implementation is provided so callers that read existing items
        // can adopt it later without a rewrite.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        let audioFileName = try container.decode(String.self, forKey: .audioFileName)
        let rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript)
        let llmTranscript = try container.decodeIfPresent(String.self, forKey: .llmTranscript)
        self.init(
            id: id,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            audioFileName: audioFileName,
            rawTranscript: rawTranscript,
            llmTranscript: llmTranscript,
            folderURL: URL(fileURLWithPath: ""),
            audioURL: URL(fileURLWithPath: "")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(audioFileName, forKey: .audioFileName)

        if let rawTranscript {
            try container.encode(rawTranscript, forKey: .rawTranscript)
        } else {
            try container.encodeNil(forKey: .rawTranscript)
        }
        if let llmTranscript {
            try container.encode(llmTranscript, forKey: .llmTranscript)
        } else {
            try container.encodeNil(forKey: .llmTranscript)
        }
    }
}

enum LocalHistoryError: LocalizedError {
    case documentsDirectoryUnavailable
    case incompleteRecording
    case audioCopyFailed(underlying: Error)
    case metadataWriteFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            "Loreta Speak could not find the Documents folder for local history."
        case .incompleteRecording:
            "Loreta Speak cannot write history before the recording has stopped."
        case .audioCopyFailed(let underlying):
            "Loreta Speak kept the recording in memory, but could not copy the audio clip into local history: \(underlying.localizedDescription)"
        case .metadataWriteFailed(let underlying):
            "Loreta Speak copied the audio clip, but could not write local history metadata: \(underlying.localizedDescription)"
        }
    }
}

final class LocalHistoryStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let historyRootURL: URL?

    init(fileManager: FileManager = .default, historyRootURL: URL? = nil) {
        self.fileManager = fileManager
        self.historyRootURL = historyRootURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func persistAudioClip(_ clip: RecordedAudioClip) throws -> LocalHistoryItem {
        guard clip.isComplete else {
            throw LocalHistoryError.incompleteRecording
        }

        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw LocalHistoryError.documentsDirectoryUnavailable
        }

        let rootURL = historyRootURL ?? documentsURL.appendingPathComponent("Loreta Speak", isDirectory: true)
        let folderURL = rootURL.appendingPathComponent(historyFolderName(for: clip), isDirectory: true)
        let audioFileName = "audio.m4a"
        let audioURL = folderURL.appendingPathComponent(audioFileName, isDirectory: false)

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        do {
            if fileManager.fileExists(atPath: audioURL.path) {
                try fileManager.removeItem(at: audioURL)
            }
            try fileManager.copyItem(at: clip.temporaryURL, to: audioURL)
        } catch {
            throw LocalHistoryError.audioCopyFailed(underlying: error)
        }

        let item = LocalHistoryItem(
            id: clip.id,
            createdAt: clip.startedAt,
            durationSeconds: clip.duration,
            audioFileName: audioFileName,
            rawTranscript: nil,
            llmTranscript: nil,
            folderURL: folderURL,
            audioURL: audioURL
        )

        try writeMetadata(for: item)
        return item
    }

    func updateTranscripts(
        rawTranscript: String?,
        llmTranscript: String?,
        for item: LocalHistoryItem
    ) throws -> LocalHistoryItem {
        let updatedItem = LocalHistoryItem(
            id: item.id,
            createdAt: item.createdAt,
            durationSeconds: item.durationSeconds,
            audioFileName: item.audioFileName,
            rawTranscript: rawTranscript,
            llmTranscript: llmTranscript,
            folderURL: item.folderURL,
            audioURL: item.audioURL
        )

        try writeMetadata(for: updatedItem)
        return updatedItem
    }

    func mostRecentCompletedItem() throws -> LocalHistoryItem? {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw LocalHistoryError.documentsDirectoryUnavailable
        }

        let rootURL = historyRootURL ?? documentsURL.appendingPathComponent("Loreta Speak", isDirectory: true)
        guard fileManager.fileExists(atPath: rootURL.path) else { return nil }

        let folderURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var latestItem: LocalHistoryItem?
        for folderURL in folderURLs {
            guard isDirectory(folderURL) else { continue }

            let metadataURL = folderURL.appendingPathComponent("metadata.json", isDirectory: false)
            guard fileManager.fileExists(atPath: metadataURL.path) else { continue }

            do {
                let data = try Data(contentsOf: metadataURL)
                let decodedItem = try decoder.decode(LocalHistoryItem.self, from: data)
                let item = LocalHistoryItem(
                    id: decodedItem.id,
                    createdAt: decodedItem.createdAt,
                    durationSeconds: decodedItem.durationSeconds,
                    audioFileName: decodedItem.audioFileName,
                    rawTranscript: decodedItem.rawTranscript,
                    llmTranscript: decodedItem.llmTranscript,
                    folderURL: folderURL,
                    audioURL: folderURL.appendingPathComponent(decodedItem.audioFileName, isDirectory: false)
                )

                guard completedTranscript(from: item) != nil else { continue }
                if latestItem == nil || item.createdAt > latestItem!.createdAt {
                    latestItem = item
                }
            } catch {
                continue
            }
        }

        return latestItem
    }

    func completedTranscript(from item: LocalHistoryItem) -> String? {
        if let llmTranscript = item.llmTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !llmTranscript.isEmpty {
            return llmTranscript
        }

        if let rawTranscript = item.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawTranscript.isEmpty {
            return rawTranscript
        }

        return nil
    }

    private func writeMetadata(for item: LocalHistoryItem) throws {
        do {
            let metadataURL = item.folderURL.appendingPathComponent("metadata.json", isDirectory: false)
            let data = try encoder.encode(item)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            throw LocalHistoryError.metadataWriteFailed(underlying: error)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func historyFolderName(for clip: RecordedAudioClip) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let shortID = String(clip.id.uuidString.prefix(8))
        return "\(formatter.string(from: clip.startedAt))-\(shortID)"
    }
}
