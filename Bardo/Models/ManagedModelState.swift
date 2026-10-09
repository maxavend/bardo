import Foundation

enum ManagedModel: String, CaseIterable, Sendable {
    case whisperTurbo
    case speakerKit
}

enum ManagedModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case preparing(Double)
    case installed
    case failed(String)
}

extension Notification.Name {
    /// Posted on the main actor when local models were installed or removed outside
    /// first-run setup: from Settings, or by a transcription that downloaded them.
    static let bardoModelsChanged = Notification.Name("Bardo.Models.Changed")
}
