enum ProcessingState: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case failed
}
