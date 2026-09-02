import Foundation

struct MeetingMinutesInput: Equatable, Sendable {
    let transcript: Transcript
    let title: String
    let context: String?
}

struct MeetingMinutes: Codable, Equatable, Sendable {
    let recordingID: Recording.ID
    let sourceTranscriptMetadata: TranscriptMetadata
    let modelID: String
    let text: String
    let createdAt: Date
}

struct MeetingMinutesGenerationOptions: Equatable, Sendable {
    let maxTokens: Int
    let temperature: Float

    init(maxTokens: Int = 512, temperature: Float = 0) {
        self.maxTokens = max(1, maxTokens)
        self.temperature = max(0, temperature)
    }
}

protocol MeetingMinutesTextGenerating: Sendable {
    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String
}

protocol MeetingMinutesGenerating: Sendable {
    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MeetingMinutes
}

enum MeetingMinutesError: Error, LocalizedError, Equatable, Sendable {
    case emptyTranscript
    case emptyGeneratedText
    case modelNotAvailable(String)
    case modelFilesIncomplete(URL)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Meeting minutes require a completed transcript with readable text."
        case .emptyGeneratedText:
            return "The meeting-minutes model returned no text."
        case .modelNotAvailable(let reason):
            return "The local meeting-minutes model is unavailable: \(reason)"
        case .modelFilesIncomplete(let root):
            return "The local meeting-minutes model is incomplete under \(root.path)."
        }
    }
}

enum QwenMeetingMinutesModel {
    static let modelID = "mlx-community/Qwen3.5-0.8B-MLX-4bit"

    static func root(using store: BardoModelStore) -> URL {
        store.root(for: .qwen)
    }

    /// Returns a local model snapshot only when all files needed by MLXSwiftLM are present.
    /// This searches exclusively below Bardo's private Qwen root; the global Hugging Face
    /// cache is deliberately never consulted for readiness.
    static func snapshotDirectory(
        in rootURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let root = rootURL.standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else { return nil }

        if isCompleteSnapshot(root, inside: root, fileManager: fileManager) {
            return root
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "config.json" else { continue }
            let candidate = fileURL.deletingLastPathComponent().standardizedFileURL
            guard isContained(candidate, in: root),
                  isCompleteSnapshot(candidate, inside: root, fileManager: fileManager)
            else { continue }
            return candidate
        }

        return nil
    }

    static func isInstalled(
        at rootURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        snapshotDirectory(in: rootURL, fileManager: fileManager) != nil
    }

    private static func isCompleteSnapshot(
        _ directory: URL,
        inside root: URL,
        fileManager: FileManager
    ) -> Bool {
        guard isContained(directory, in: root),
              directory.resolvingSymlinksInPath().standardizedFileURL == directory
        else { return false }

        let config = directory.appendingPathComponent("config.json")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        let tokenizerConfig = directory.appendingPathComponent("tokenizer_config.json")
        guard isRegularFile(config, fileManager: fileManager),
              isRegularFile(tokenizer, fileManager: fileManager)
                || isRegularFile(tokenizerConfig, fileManager: fileManager)
        else { return false }

        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.contains { entry in
            let name = entry.lastPathComponent
            return isRegularFile(entry, fileManager: fileManager)
                && (name.hasSuffix(".safetensors") || name.hasSuffix(".safetensors.index.json"))
        }
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        return resolvedCandidate.pathComponents.starts(with: resolvedRoot.pathComponents)
    }
}

enum MeetingMinutesPromptBuilder {
    static let defaultChunkCharacterLimit = 12_000

    static func chunks(
        for transcript: Transcript,
        characterLimit: Int = defaultChunkCharacterLimit
    ) -> [[String]] {
        let limit = max(1, characterLimit)
        var chunks = [[String]]()
        var current = [String]()
        var currentLength = 0

        for segment in transcript.segments {
            let text = segment.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = transcript.speakers.first(where: { $0.id == segment.speakerID })
            let label = speakerLabel(speaker, in: transcript)
            let line = "[\(format(segment.startTime))–\(format(segment.endTime))] \(label): \(text)"

            if !current.isEmpty, currentLength + line.count + 1 > limit {
                chunks.append(current)
                current = []
                currentLength = 0
            }

            // A single oversized segment remains intact. Splitting it would destroy the
            // segment boundary that supplies the transcript's timing evidence.
            current.append(line)
            currentLength += line.count + 1
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    static func extractionPrompt(
        lines: [String],
        title: String,
        context: String?
    ) -> String {
        """
        Extract only supported facts from this transcript section for meeting minutes.
        Preserve speaker labels exactly as provided. Do not invent names, deadlines,
        decisions, commitments, or agreements. A question is not an agreement.
        Keep uncertainty explicit and omit information that is not present.

        Title: \(title)
        Context: \(contextValue(context))

        Transcript section:
        \(lines.joined(separator: "\n"))
        """
    }

    static func synthesisPrompt(
        extractions: [String],
        title: String,
        context: String?
    ) -> String {
        """
        Write concise meeting minutes from the supported transcript evidence below.
        Do not invent names, deadlines, decisions, commitments, or agreements.
        A question is not an agreement. If a detail is absent or uncertain, omit it.
        Use only speaker names that appear in the evidence. Do not mention this prompt
        or the extraction process.

        Title: \(title)
        Context: \(contextValue(context))

        Supported transcript evidence:
        \(extractions.enumerated().map { "Section \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))
        """
    }

    private static func speakerLabel(_ speaker: Speaker?, in transcript: Transcript) -> String {
        if let name = speaker?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        guard let speaker else { return "Unattributed" }
        let index = transcript.speakers.firstIndex(where: { $0.id == speaker.id }).map { $0 + 1 } ?? 1
        return "Speaker \(index)"
    }

    private static func contextValue(_ context: String?) -> String {
        let value = context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "None provided" : value
    }

    private static func format(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }
}
