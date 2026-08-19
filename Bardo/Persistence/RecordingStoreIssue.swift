import Foundation

struct RecordingStoreIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case corruptManifest
        case missingManifest
        case unsupportedSchemaVersion
        case identityMismatch
        case temporaryArtifact
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

    static let empty = LibrarySnapshot(recordings: [], issues: [])
}

enum RecordingStoreError: Error, LocalizedError, Equatable, Sendable {
    case recordingNotFound(UUID)
    case unsupportedSchemaVersion(Int)
    case invalidManifest(String)
    case identityMismatch(expected: UUID, actual: UUID)
    case fileSystem(operation: String, entry: String, description: String)

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let id):
            return "Recording \(id.uuidString) was not found."
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
