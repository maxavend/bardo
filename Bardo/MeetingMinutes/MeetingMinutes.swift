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
    let topP: Float
    let repetitionPenalty: Float?
    let repetitionContextSize: Int

    init(
        maxTokens: Int = 2048,
        temperature: Float = 0,
        topP: Float = 0.9,
        repetitionPenalty: Float? = 1.2,
        repetitionContextSize: Int = 128
    ) {
        self.maxTokens = max(1, maxTokens)
        self.temperature = max(0, temperature)
        self.topP = max(0, min(1, topP))
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = max(0, repetitionContextSize)
    }
}

enum MeetingMinutesStage: Equatable, Sendable {
    case preparingModel
    case extracting(current: Int, total: Int)
    case synthesizing
}

struct MeetingMinutesProgressSnapshot: Equatable, Sendable {
    let stage: MeetingMinutesStage
    let fractionCompleted: Double
    let message: String
}

protocol MeetingMinutesTextGenerating: Sendable {
    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws
    func reset() async

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void,
        onStreamChunk: (@Sendable (String) -> Void)?
    ) async throws -> String
}

extension MeetingMinutesTextGenerating {
    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1)
    }

    func reset() async {}

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await generate(
            prompt: prompt,
            options: options,
            progress: progress,
            onStreamChunk: nil
        )
    }
}

protocol MeetingMinutesGenerating: Sendable {
    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws
    func reset() async

    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MeetingMinutes

    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (MeetingMinutesProgressSnapshot) -> Void,
        onStreamChunk: (@Sendable (String) -> Void)?
    ) async throws -> MeetingMinutes
}

extension MeetingMinutesGenerating {
    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1)
    }

    func reset() async {}

    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MeetingMinutes {
        try await generate(
            from: input,
            progress: { snapshot in progress(snapshot.fractionCompleted) },
            onStreamChunk: nil
        )
    }

    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (MeetingMinutesProgressSnapshot) -> Void,
        onStreamChunk: (@Sendable (String) -> Void)?
    ) async throws -> MeetingMinutes {
        try await generate(
            from: input,
            progress: { fraction in
                progress(MeetingMinutesProgressSnapshot(
                    stage: .synthesizing,
                    fractionCompleted: fraction,
                    message: ""
                ))
            }
        )
    }
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
        context: String?,
        languageCode: String? = nil
    ) -> String {
        let languageGuide = languageInstruction(for: languageCode)
        return """
        Extract only supported facts from this transcript section for meeting minutes.
        Preserve speaker labels exactly as provided. Do not invent names, deadlines,
        decisions, or agreements. Do not turn an unsupported commitment into a fact. A question is not an agreement.
        Keep uncertainty explicit and omit information that is not present.
        \(languageGuide)

        Title: \(title)
        Context: \(contextValue(context))

        Transcript section:
        \(lines.joined(separator: "\n"))
        """
    }

    static func extractionPrompt(
        lines: [String],
        title: String,
        context: String?
    ) -> String {
        extractionPrompt(lines: lines, title: title, context: context, languageCode: nil)
    }

    static func synthesisPrompt(
        extractions: [String],
        title: String,
        context: String?,
        languageCode: String? = nil,
        isSingleTranscript: Bool = false
    ) -> String {
        let languageGuide = languageInstruction(for: languageCode)
        let evidenceBlock = isSingleTranscript && extractions.count == 1
            ? extractions[0]
            : extractions.enumerated().map { "Section \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")

        return """
        Write comprehensive, well-structured, and highly relevant meeting minutes from the supported transcript evidence below.
        \(languageGuide)

        Structure the meeting minutes clearly using clean Markdown with the following sections (translate section headers to the conversation language):
        - # [Title of Meeting / Minuta de Reunión]
        - ## Executive Summary / Resumen Ejecutivo: Clear and comprehensive overview of the meeting's purpose, background, and core themes.
        - ## Key Discussion Points / Temas Tratados y Discusión: In-depth breakdown of the main discussions, arguments, nuances, and participant contributions. Attribute statements to speakers accurately.
        - ## Decisions and Agreements / Acuerdos y Decisiones: Explicit resolutions and consensus reached.
        - ## Action Items & Next Steps / Tareas y Compromisos: Concrete actionable items, specifying the responsible owner and deadlines whenever mentioned.
        - ## Pending Items & Open Questions / Asuntos Pendientes y Preguntas Abiertas: Unresolved topics or points requiring follow-up.

        Strict Grounding Rules:
        - Do not invent names, deadlines, decisions, or agreements. Do not turn an unsupported commitment into a fact.
        - A question is not an agreement. If a detail is absent or uncertain, omit it.
        - Use only speaker names that appear in the evidence.
        - Concision and Non-Repetition: Do not repeat sentences, bullet points, or sections. Once all facts from the evidence are summarized, conclude the document immediately.
        - No repitas ideas, frases ni secciones. Una vez cubiertos los puntos de la conversación, finaliza la redacción sin repetir información.
        - Do not mention this prompt or the extraction process. Begin directly with the meeting minutes.

        Title: \(title)
        Context: \(contextValue(context))

        Supported transcript evidence:
        \(evidenceBlock)
        """
    }

    static func synthesisPrompt(
        extractions: [String],
        title: String,
        context: String?
    ) -> String {
        synthesisPrompt(extractions: extractions, title: title, context: context, languageCode: nil, isSingleTranscript: false)
    }

    static func languageInstruction(for languageCode: String?) -> String {
        let code = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let code, !code.isEmpty {
            let locale = Locale(identifier: "en_US")
            let languageName = locale.localizedString(forLanguageCode: code) ?? code
            return "LANGUAGE REQUIREMENT: The conversation is in \(languageName) (code: \(code)). You MUST write the entire meeting minutes, including all section headings, summaries, bullet points, and action items, exclusively in \(languageName)."
        } else {
            return "LANGUAGE REQUIREMENT: Write the entire meeting minutes, including all section headings, summaries, bullet points, and action items, strictly in the predominant language of the conversation transcript (for example, if the transcript is in Spanish, write everything in Spanish; if in English, in English)."
        }
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

// MARK: - Repetition Detector & Cleaner

public struct RepetitionDetector: Sendable {
    /// Checks whether the text has entered an infinite repetitive loop at the tail.
    /// Returns the character index in text where the repeating loop starts, or nil if no repetition is detected.
    public static func detectRepetition(in text: String) -> Int? {
        guard text.count >= 40 else { return nil }

        // 1. Line-level repetition:
        // If the exact same line (at least 8 characters) is repeated 3 times at the tail.
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if lines.count >= 3 {
            let last = lines[lines.count - 1]
            let prev1 = lines[lines.count - 2]
            let prev2 = lines[lines.count - 3]
            if last.count >= 8 && last == prev1 && last == prev2 {
                if let firstRange = text.range(of: last) {
                    let afterFirst = text[firstRange.upperBound...]
                    if let secondRange = afterFirst.range(of: last) {
                        return text.distance(from: text.startIndex, to: secondRange.lowerBound)
                    }
                }
            }
        }

        // 2. Substring cycle repetition:
        // A pattern of length L (8...200) repeated 3 times consecutively at the tail.
        let count = text.count
        let maxPatternLength = min(200, count / 3)
        let minPatternLength = 8

        if maxPatternLength >= minPatternLength {
            for patternLen in (minPatternLength...maxPatternLength).reversed() {
                let end3 = text.endIndex
                let start3 = text.index(end3, offsetBy: -patternLen)
                let start2 = text.index(start3, offsetBy: -patternLen)
                let start1 = text.index(start2, offsetBy: -patternLen)

                let p3 = text[start3..<end3]
                let p2 = text[start2..<start3]
                let p1 = text[start1..<start2]

                if p1 == p2 && p2 == p3 {
                    return text.distance(from: text.startIndex, to: start2)
                }
            }
        }

        // 3. For longer patterns (>= 45 chars), 2 identical consecutive repetitions at the tail
        // indicate an unmistakable LLM generation loop.
        let longMaxPattern = min(300, count / 2)
        if longMaxPattern >= 45 {
            for patternLen in (45...longMaxPattern).reversed() {
                let end2 = text.endIndex
                let start2 = text.index(end2, offsetBy: -patternLen)
                let start1 = text.index(start2, offsetBy: -patternLen)

                let p2 = text[start2..<end2]
                let p1 = text[start1..<start2]

                if p1 == p2 {
                    return text.distance(from: text.startIndex, to: start2)
                }
            }
        }

        return nil
    }

    /// Trims any trailing repeated cycle if detected.
    public static func cleanRepetition(from text: String) -> String {
        guard let cutIndex = detectRepetition(in: text) else {
            return text
        }
        let index = text.index(text.startIndex, offsetBy: cutIndex)
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
