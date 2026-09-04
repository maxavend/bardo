import Foundation

enum ManagedModel: String, CaseIterable, Sendable {
    case whisperTurbo
    case speakerKit
    case meetingMinutes
}

enum ManagedModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case preparing(Double)
    case installed
    case failed(String)
}
