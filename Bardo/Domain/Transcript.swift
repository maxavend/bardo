import Foundation

struct Speaker: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String?

    init(id: UUID = UUID(), name: String? = nil) {
        self.id = id
        self.name = name
    }
}

struct TranscriptWord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let probability: Float?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        probability: Float? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.probability = probability
    }
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    var speakerID: Speaker.ID?
    var text: String
    var words: [TranscriptWord]
    var editedText: String?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerID: Speaker.ID? = nil,
        text: String,
        words: [TranscriptWord] = [],
        editedText: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
        self.text = text
        self.words = words
        self.editedText = editedText
    }

    var displayText: String {
        TranscriptTextSanitizer.sanitize(editedText ?? text)
    }
}

enum TranscriptionCompletion: String, Codable, Equatable, Sendable {
    case complete
    case partial
}

/// Evidence about the audio range that was successfully handed through Whisper's
/// deterministic decode path. This is intentionally independent of the timestamp of the
/// last spoken word: trailing/intermediate silence is valid audio and must not be mistaken
/// for missing transcription work.
struct TranscriptionCoverage: Codable, Equatable, Sendable {
    let completion: TranscriptionCompletion
    let sourceDuration: TimeInterval
    let processedDuration: TimeInterval
    let expectedSampleCount: Int
    let processedSampleCount: Int

    init(
        completion: TranscriptionCompletion,
        sourceDuration: TimeInterval,
        processedDuration: TimeInterval,
        expectedSampleCount: Int,
        processedSampleCount: Int
    ) {
        self.completion = completion
        self.sourceDuration = sourceDuration
        self.processedDuration = processedDuration
        self.expectedSampleCount = expectedSampleCount
        self.processedSampleCount = processedSampleCount
    }

    var isComplete: Bool { completion == .complete }
}

struct TranscriptMetadata: Codable, Equatable, Sendable {
    let engine: String
    let engineVersion: String
    let modelID: String
    let createdAt: Date
    let coverage: TranscriptionCoverage?

    init(
        engine: String,
        engineVersion: String,
        modelID: String,
        createdAt: Date = Date(),
        coverage: TranscriptionCoverage? = nil
    ) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.modelID = modelID
        self.createdAt = createdAt
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey {
        case engine
        case engineVersion
        case modelID
        case createdAt
        case coverage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decode(String.self, forKey: .engine)
        engineVersion = try container.decode(String.self, forKey: .engineVersion)
        modelID = try container.decode(String.self, forKey: .modelID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        coverage = try container.decodeIfPresent(TranscriptionCoverage.self, forKey: .coverage)
    }
}

struct DiarizationMetadata: Codable, Equatable, Sendable {
    let engine: String
    let engineVersion: String
    let modelID: String
    let createdAt: Date

    init(
        engine: String,
        engineVersion: String,
        modelID: String,
        createdAt: Date = Date()
    ) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.modelID = modelID
        self.createdAt = createdAt
    }
}

struct Transcript: Codable, Equatable, Sendable {
    let recordingID: Recording.ID
    var languageCode: String?
    var speakers: [Speaker]
    var segments: [TranscriptSegment]
    let metadata: TranscriptMetadata
    var diarizationMetadata: DiarizationMetadata?

    init(
        recordingID: Recording.ID,
        languageCode: String? = nil,
        speakers: [Speaker] = [],
        segments: [TranscriptSegment] = [],
        metadata: TranscriptMetadata,
        diarizationMetadata: DiarizationMetadata? = nil
    ) {
        self.recordingID = recordingID
        self.languageCode = languageCode
        self.speakers = speakers
        self.segments = segments
        self.metadata = metadata
        self.diarizationMetadata = diarizationMetadata
    }

    var text: String {
        segments
            .map(\.displayText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isComplete: Bool {
        metadata.coverage?.completion != .partial
    }

    var hasManualTextEdits: Bool {
        segments.contains { $0.editedText != nil }
    }

    var hasNamedSpeakers: Bool {
        speakers.contains { speaker in
            guard let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !name.isEmpty
        }
    }

    var hasManualChanges: Bool {
        hasManualTextEdits || hasNamedSpeakers
    }
}
