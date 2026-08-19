import Foundation
import ScreenCaptureKit

final class SystemContentSelection: @unchecked Sendable {
    let filter: SCContentFilter?
    let testIdentifier: String?

    init(filter: SCContentFilter) {
        self.filter = filter
        self.testIdentifier = nil
    }

    init(testIdentifier: String) {
        self.filter = nil
        self.testIdentifier = testIdentifier
    }
}

enum SystemContentSelectionEvent: @unchecked Sendable {
    case selected(SystemContentSelection, isUpdate: Bool)
    case cancelled(isUpdate: Bool)
    case failed(String)
}

@MainActor
protocol SystemContentSelecting: AnyObject {
    var eventHandler: ((SystemContentSelectionEvent) -> Void)? { get set }
    func present()
    func deactivate()
}

struct CapturedAudioTrackTiming: Equatable, Sendable {
    let firstPresentationTime: TimeInterval
    let lastPresentationTime: TimeInterval
}

struct SystemAudioCaptureResult: Equatable, Sendable {
    let systemTrack: CapturedAudioTrackTiming?
    let microphoneTrack: CapturedAudioTrackTiming?
    let systemError: String?
    let microphoneError: String?
    let streamStopError: String?
}

enum SystemAudioCaptureBackendEvent: Equatable, Sendable {
    case interrupted(String)
}

@MainActor
protocol SystemAudioCapturing: AnyObject {
    var eventHandler: ((SystemAudioCaptureBackendEvent) -> Void)? { get set }
    var currentTime: TimeInterval { get }

    func start(
        selection: SystemContentSelection,
        includeMicrophone: Bool,
        systemURL: URL,
        microphoneURL: URL?
    ) async throws

    func update(selection: SystemContentSelection) async throws
    func stop() async -> SystemAudioCaptureResult
}

enum SystemAudioCaptureError: Error, LocalizedError, Equatable, Sendable {
    case invalidSelection
    case alreadyCapturing
    case notCapturing
    case missingMicrophoneDestination
    case noAudioSamples(String)
    case writer(String)
    case screenCapture(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "The selected macOS content is no longer available for capture."
        case .alreadyCapturing:
            return "A system-audio capture is already active."
        case .notCapturing:
            return "No system-audio capture is active."
        case .missingMicrophoneDestination:
            return "The dual-source capture has no microphone staging destination."
        case .noAudioSamples(let source):
            return "No readable \(source) audio samples were received."
        case .writer(let message):
            return "Bardo could not write captured audio: \(message)"
        case .screenCapture(let message):
            return "ScreenCaptureKit could not continue: \(message)"
        }
    }
}
