import Foundation

struct Recording: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var duration: TimeInterval?
    var sources: Set<AudioSource>
    var processingState: ProcessingState
    var audioAssets: [AudioAsset]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval? = nil,
        sources: Set<AudioSource>,
        processingState: ProcessingState = .pending,
        audioAssets: [AudioAsset] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.sources = sources
        self.processingState = processingState
        self.audioAssets = audioAssets
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case duration
        case sources
        case processingState
        case audioAssets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        sources = try container.decode(Set<AudioSource>.self, forKey: .sources)
        processingState = try container.decode(ProcessingState.self, forKey: .processingState)
        audioAssets = try container.decodeIfPresent([AudioAsset].self, forKey: .audioAssets) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encode(sources, forKey: .sources)
        try container.encode(processingState, forKey: .processingState)
        try container.encode(audioAssets, forKey: .audioAssets)
    }
}
