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

struct TranscriptMetadata: Codable, Equatable, Sendable {
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
