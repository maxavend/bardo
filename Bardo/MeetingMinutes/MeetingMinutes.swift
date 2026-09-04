import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

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
    let analysis: MeetingAnalysis?
    let sourceTranscriptHash: String?
    let modelRevision: String?
    let promptVersion: String?
    let pipelineVersion: String?

    init(
        recordingID: Recording.ID,
        sourceTranscriptMetadata: TranscriptMetadata,
        modelID: String,
        text: String,
        createdAt: Date,
        analysis: MeetingAnalysis? = nil,
        sourceTranscriptHash: String? = nil,
        modelRevision: String? = nil,
        promptVersion: String? = nil,
        pipelineVersion: String? = nil
    ) {
        self.recordingID = recordingID
        self.sourceTranscriptMetadata = sourceTranscriptMetadata
        self.modelID = modelID
        self.text = text
        self.createdAt = createdAt
        self.analysis = analysis
        self.sourceTranscriptHash = sourceTranscriptHash
        self.modelRevision = modelRevision
        self.promptVersion = promptVersion
        self.pipelineVersion = pipelineVersion
    }

    func isStale(comparedTo transcript: Transcript) -> Bool {
        guard let sourceTranscriptHash else { return false }
        return sourceTranscriptHash != TranscriptFingerprint.hash(transcript)
    }
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

enum MeetingMinutesSetupStage: Equatable, Sendable {
    case downloading
    case loading
    case checkingRuntime
}

struct MeetingMinutesSetupProgressSnapshot: Equatable, Sendable {
    let stage: MeetingMinutesSetupStage
    let fractionCompleted: Double
}

struct MeetingMinutesProgressSnapshot: Equatable, Sendable {
    let stage: MeetingMinutesStage
    let fractionCompleted: Double
    let message: String
}

protocol MeetingMinutesTextGenerating: Sendable {
    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws
    func prepareForUse(
        setupProgress: @escaping @Sendable (MeetingMinutesSetupProgressSnapshot) -> Void
    ) async throws
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

    func prepareForUse(
        setupProgress: @escaping @Sendable (MeetingMinutesSetupProgressSnapshot) -> Void
    ) async throws {
        try await prepareForUse { fraction in
            setupProgress(.init(stage: .downloading, fractionCompleted: fraction))
        }
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

enum TranscriptFingerprint {
    static func hash(_ transcript: Transcript) -> String {
        let canonical = transcript.segments.map { segment in
            "\(segment.id.uuidString)|\(segment.startTime)|\(segment.endTime)|\(segment.speakerID?.uuidString ?? "")|\(segment.displayText)"
        }.joined(separator: "\n")
        + "\n"
        + transcript.speakers.map { "\($0.id.uuidString)|\($0.name ?? "")" }.joined(separator: "\n")
        + "\n\(transcript.languageCode ?? "")"
        return SHA256Hex.digest(Data(canonical.utf8))
    }
}

private enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return data.base64EncodedString()
        #endif
    }
}

struct MeetingMinutesChunk: Equatable, Sendable {
    let segments: [TranscriptSegment]

    var sourceSegmentIDs: [UUID] { segments.map(\.id) }
}

struct MeetingMinutesChunkingConfiguration: Equatable, Sendable {
    let targetTokens: Int
    let overlapSegmentCount: Int

    init(targetTokens: Int? = nil, overlapSegmentCount: Int = 1) {
        self.targetTokens = max(1, targetTokens ?? Self.adaptiveTargetTokens)
        self.overlapSegmentCount = max(0, overlapSegmentCount)
    }

    static var adaptiveTargetTokens: Int {
        let sixteenGB = 16 * 1_024 * 1_024 * 1_024
        return ProcessInfo.processInfo.physicalMemory >= UInt64(sixteenGB) ? 7_000 : 3_500
    }
}

enum MeetingMinutesPromptBuilder {
    static let pipelineVersion = "2"
    static let promptVersion = "1"

    static func chunks(
        for transcript: Transcript,
        configuration: MeetingMinutesChunkingConfiguration = .init()
    ) -> [MeetingMinutesChunk] {
        let segments = transcript.segments.filter {
            !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !segments.isEmpty else { return [] }

        var chunks = [MeetingMinutesChunk]()
        var start = 0
        while start < segments.count {
            var end = start
            var tokens = 0
            while end < segments.count {
                let segmentTokens = max(1, segments[end].displayText.count / 4)
                if end > start, tokens + segmentTokens > configuration.targetTokens { break }
                tokens += segmentTokens
                end += 1
            }
            chunks.append(MeetingMinutesChunk(segments: Array(segments[start..<end])))
            guard end < segments.count else { break }
            start = max(start + 1, end - configuration.overlapSegmentCount)
        }
        return chunks
    }

    static func lines(for chunk: MeetingMinutesChunk, transcript: Transcript) -> [String] {
        chunk.segments.map { segment in
            let speaker = transcript.speakers.first(where: { $0.id == segment.speakerID })
            let label = speakerLabel(speaker, in: transcript)
            return "[segment_id=\(segment.id.uuidString)][\(format(segment.startTime))–\(format(segment.endTime))] \(label): \(segment.displayText)"
        }
    }

    static func extractionPrompt(
        chunk: MeetingMinutesChunk,
        transcript: Transcript,
        title: String,
        context: String?,
        languageCode: String? = nil
    ) -> String {
        """
        MAP: extract conservative, local evidence from this transcript section.
        Return JSON only as an array of objects with exactly these fields:
        type (fact, context, proposal, preference, hypothesis, decision, agreement, pending, openQuestion, risk, nextStep),
        topic, statement, rationale, responsible, validator, certainty (explicit, qualified, unresolved),
        sourceSegmentIDs, startTime, endTime.
        Use the segment_id values from the transcript. Keep responsible nil unless the transcript explicitly assigns the task.
        A nearby person may be a validator or mentionedPerson, not a responsible owner. A question is not an agreement.
        Preserve proposals, preferences, hypotheses, unresolved items, and the reasons behind decisions. Never increase certainty.
        Exclude greetings, jokes, personal conversation, filler, ASR noise, and empty confirmations unless they affect the meeting.
        Do not infer external knowledge, advice, deadlines, names, or decisions.
        \(languageInstruction(for: languageCode))

        Title: \(title)
        Context: \(contextValue(context))

        Transcript section:
        \(lines(for: chunk, transcript: transcript).joined(separator: "\n"))
        """
    }

    static func consolidationPrompt(
        evidenceJSON: String,
        title: String,
        context: String?,
        languageCode: String? = nil
    ) -> String {
        """
        REDUCE: reconstruct the final semantic state of the meeting from the evidence below.
        Return JSON only with fields summary, topics, agreements, pending, risks, nextSteps, conclusion.
        Each topic has title, context, criteria, evidence, decisions, pending. Each pending/nextSteps item has statement,
        responsible, validator, sourceSegmentIDs. Preserve sourceSegmentIDs and rationale from evidence.
        Group evidence across sections, order it temporally, deduplicate it, and reconcile proposals with later decisions.
        A later decision supersedes an earlier proposal on the same issue; retain the proposal only as context.
        Keep unresolved alternatives, open questions, risks, and validation work. Do not force consensus.
        Never promote proposal to decision, preference to agreement, hypothesis to fact, or mentioned person to responsible.
        Use responsible only when explicitly assigned; otherwise use nil and preserve validator separately.
        Do not add recommendations, industry practices, facts, or people absent from the evidence.
        \(languageInstruction(for: languageCode))

        Title: \(title)
        Context: \(contextValue(context))

        Evidence:
        \(evidenceJSON)
        """
    }

    static func renderPrompt(
        analysisJSON: String,
        title: String,
        context: String?,
        languageCode: String? = nil
    ) -> String {
        """
        RENDER: write a professional meeting minute from the consolidated analysis below.
        Use clean Markdown and only the information in the analysis. Do not mention MAP, REDUCE, JSON, prompts, or the model.
        Use a dynamic structure: omit empty sections and never write artificial "None" or generic risks.
        Include date and identifiable participants only when present in the analysis/evidence.
        Preserve uncertainty, rationale, decision evolution, open questions, validators, and provenance where useful.
        The executive summary must stand alone. Do not repeat the index as the summary.
        \(languageInstruction(for: languageCode))

        Suggested structure when supported: title, date, objective, participants, executive summary, numbered topics with
        context/criteria/decisions/pending, consolidated agreements, pending and validation, risks, immediate next steps,
        conclusion. Do not force headings that have no content.

        Title: \(title)
        Context: \(contextValue(context))

        Consolidated analysis:
        \(analysisJSON)
        """
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
