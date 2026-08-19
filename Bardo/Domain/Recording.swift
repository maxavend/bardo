import Foundation

struct Recording: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var duration: TimeInterval?
    var sources: Set<AudioSource>
    var processingState: ProcessingState

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval? = nil,
        sources: Set<AudioSource>,
        processingState: ProcessingState = .pending
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.sources = sources
        self.processingState = processingState
    }
}
