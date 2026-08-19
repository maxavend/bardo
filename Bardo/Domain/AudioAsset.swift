import Foundation

struct AudioMetadata: Codable, Equatable, Sendable {
    let duration: TimeInterval
    let codec: String
    let sampleRate: Double
    let channelCount: UInt32
}

struct AudioAsset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let originalFileName: String
    let fileExtension: String
    let metadata: AudioMetadata

    init(
        id: UUID = UUID(),
        originalFileName: String,
        fileExtension: String,
        metadata: AudioMetadata
    ) {
        self.id = id
        self.originalFileName = originalFileName
        self.fileExtension = fileExtension.lowercased()
        self.metadata = metadata
    }
}
