import Foundation

enum TranscriptionBackend: String, Codable, CaseIterable, Sendable {
    case parakeet
    case whisperKit

    static let parakeetModelID = "parakeet-tdt-0.6b-v3"
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
