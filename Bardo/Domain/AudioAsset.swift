import Foundation

enum AudioAssetRole: String, Codable, CaseIterable, Sendable {
    case importedOriginal
    case microphoneOriginal
    case systemOriginal
    case conversationMix

    var isDerived: Bool {
        self == .conversationMix
    }

    var playbackPriority: Int {
        switch self {
        case .conversationMix: return 0
        case .importedOriginal: return 1
        case .systemOriginal: return 2
        case .microphoneOriginal: return 3
        }
    }
}

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
    let role: AudioAssetRole
    let timelineOffset: TimeInterval
    let derivedFromAssetIDs: [UUID]

    init(
        id: UUID = UUID(),
        originalFileName: String,
        fileExtension: String,
        metadata: AudioMetadata,
        role: AudioAssetRole = .importedOriginal,
        timelineOffset: TimeInterval = 0,
        derivedFromAssetIDs: [UUID] = []
    ) {
        self.id = id
        self.originalFileName = originalFileName
        self.fileExtension = fileExtension.lowercased()
        self.metadata = metadata
        self.role = role
        self.timelineOffset = max(0, timelineOffset.isFinite ? timelineOffset : 0)
        self.derivedFromAssetIDs = derivedFromAssetIDs
    }
}
