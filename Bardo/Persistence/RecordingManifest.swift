import Foundation

struct RecordingManifestV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval?
    let sources: [AudioSource]
    let processingState: ProcessingState

    init(recording: Recording) {
        schemaVersion = Self.currentSchemaVersion
        id = recording.id
        title = recording.title
        createdAt = recording.createdAt
        duration = recording.duration
        sources = recording.sources.sorted { $0.rawValue < $1.rawValue }
        processingState = recording.processingState
    }

    var recording: Recording {
        Recording(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: duration,
            sources: Set(sources),
            processingState: processingState
        )
    }
}

struct RecordingManifestHeader: Decodable, Sendable {
    let schemaVersion: Int
}
