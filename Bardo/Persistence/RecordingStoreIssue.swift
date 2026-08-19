import Foundation

struct RecordingStoreIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case corruptManifest
        case missingManifest
        case unsupportedSchemaVersion
        case identityMismatch
        case temporaryArtifact
        case temporaryAudioArtifact
        case missingAudioFile
        case missingDerivedAudioFile
        case unexpectedEntry
        case unreadableEntry
    }

    let kind: Kind
    let recordingID: UUID?
    let entryName: String
    let message: String

    var id: String {
        "\(entryName)|\(kind.rawValue)|\(recordingID?.uuidString ?? "none")"
    }
}

struct LibrarySnapshot: Equatable, Sendable {
    let recordings: [Recording]
    let issues: [RecordingStoreIssue]
}

enum RecordingStoreError: Error, LocalizedError, Equatable, Sendable {
    case recordingNotFound(UUID)
    case recordingAlreadyExists(UUID)
    case audioAssetNotFound(recordingID: UUID, audioAssetID: UUID)
    case audioAssetFileSetMismatch(recordingID: UUID, expected: Int, supplied: Int)
    case managedAudioMissing(recordingID: UUID, audioAssetID: UUID)
    case unsupportedSchemaVersion(Int)
    case invalidManifest(String)
    case identityMismatch(expected: UUID, actual: UUID)
    case fileSystem(operation: String, entry: String, description: String)

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let id):
            return "Recording \(id.uuidString) was not found."
        case .recordingAlreadyExists(let id):
            return "Recording \(id.uuidString) already exists."
        case .audioAssetNotFound(let recordingID, let audioAssetID):
            return "Audio \(audioAssetID.uuidString) is not registered for recording \(recordingID.uuidString)."
        case .audioAssetFileSetMismatch(let recordingID, let expected, let supplied):
            return "Recording \(recordingID.uuidString) expected \(expected) managed audio files but received \(supplied)."
        case .managedAudioMissing(let recordingID, let audioAssetID):
            return "Managed audio \(audioAssetID.uuidString) for recording \(recordingID.uuidString) is missing."
        case .unsupportedSchemaVersion(let version):
            return "Manifest schema version \(version) is not supported."
        case .invalidManifest(let description):
            return "The recording manifest is invalid: \(description)"
        case .identityMismatch(let expected, let actual):
            return "Manifest identity \(actual.uuidString) does not match directory identity \(expected.uuidString)."
        case .fileSystem(let operation, let entry, let description):
            return "Could not \(operation) \(entry): \(description)"
        }
    }
}
