import Foundation

enum ManagedModel: String, CaseIterable, Sendable {
    case whisperBalanced
    case whisperMaximumAccuracy
    case parakeet
    case speakerKit
    case qwen
}

enum ManagedModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case preparing(Double)
    case installed
    case failed(String)
}
