import Foundation

struct RecordingManifestV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let title: String
    let createdAtEpochSeconds: TimeInterval
    let duration: TimeInterval?
    let sources: [AudioSource]
    let processingState: ProcessingState

    init(recording: Recording) {
        schemaVersion = Self.currentSchemaVersion
        id = recording.id
        title = recording.title
        createdAtEpochSeconds = recording.createdAt.timeIntervalSince1970
        duration = recording.duration
        sources = recording.sources.sorted { $0.rawValue < $1.rawValue }
        processingState = recording.processingState
    }

    var recording: Recording {
        Recording(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAtEpochSeconds),
            duration: duration,
            sources: Set(sources),
            processingState: processingState
        )
    }
}

struct RecordingManifestHeader: Decodable, Sendable {
    let schemaVersion: Int
}
