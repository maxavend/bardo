import Foundation

enum TranscriptionBackend: String, Codable, CaseIterable, Sendable {
    case parakeet
    case whisperKit
}

enum TranscriptionPreset: String, Codable, CaseIterable, Sendable {
    case instant
    case balanced
    case maximumAccuracy
}

struct TranscriptionSelection: Codable, Equatable, Sendable {
    let preset: TranscriptionPreset
    let backend: TranscriptionBackend
    let modelID: String
}
