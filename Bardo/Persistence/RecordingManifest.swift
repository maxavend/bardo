import Foundation

struct RecordingManifestV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let title: String
    let createdAtEpochSeconds: TimeInterval
    let duration: TimeInterval?
    let sources: [AudioSource]
    let processingState: ProcessingState

    var recording: Recording {
        Recording(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAtEpochSeconds),
            duration: duration,
            sources: Set(sources),
            processingState: processingState,
            audioAssets: []
        )
    }
}

struct RecordingManifestV2: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    struct AudioAssetRecord: Codable, Equatable, Sendable {
        let id: UUID
        let originalFileName: String
        let fileExtension: String
        let duration: TimeInterval
        let codec: String
        let sampleRate: Double
        let channelCount: UInt32

        init(asset: AudioAsset) {
            id = asset.id
            originalFileName = asset.originalFileName
            fileExtension = asset.fileExtension
            duration = asset.metadata.duration
            codec = asset.metadata.codec
            sampleRate = asset.metadata.sampleRate
            channelCount = asset.metadata.channelCount
        }

        var asset: AudioAsset {
            AudioAsset(
                id: id,
                originalFileName: originalFileName,
                fileExtension: fileExtension,
                metadata: AudioMetadata(
                    duration: duration,
                    codec: codec,
                    sampleRate: sampleRate,
                    channelCount: channelCount
                )
            )
        }
    }

    let schemaVersion: Int
    let id: UUID
    let title: String
    let createdAtEpochSeconds: TimeInterval
    let duration: TimeInterval?
    let sources: [AudioSource]
    let processingState: ProcessingState
    let audioAssets: [AudioAssetRecord]

    init(recording: Recording) {
        schemaVersion = Self.currentSchemaVersion
        id = recording.id
        title = recording.title
        createdAtEpochSeconds = recording.createdAt.timeIntervalSince1970
        duration = recording.duration
        sources = recording.sources.sorted { $0.rawValue < $1.rawValue }
        processingState = recording.processingState
        audioAssets = recording.audioAssets.map(AudioAssetRecord.init(asset:))
    }

    var recording: Recording {
        Recording(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAtEpochSeconds),
            duration: duration,
            sources: Set(sources),
            processingState: processingState,
            audioAssets: audioAssets.map(\.asset)
        )
    }
}

struct RecordingManifestHeader: Decodable, Sendable {
    let schemaVersion: Int
}
