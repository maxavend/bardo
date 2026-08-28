enum ProcessingState: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case partial
    case failed
}
