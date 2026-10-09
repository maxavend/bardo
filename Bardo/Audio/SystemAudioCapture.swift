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
    /// Set when the track ended early or skipped audio but still produced a readable file.
    var warning: String? = nil
}

struct SystemAudioCaptureResult: Equatable, Sendable {
    let systemTrack: CapturedAudioTrackTiming?
    let microphoneTrack: CapturedAudioTrackTiming?
    let systemError: String?
    let microphoneError: String?
    let streamStopError: String?
}

enum SystemAudioCaptureBackendEvent: Equatable, Sendable {
    /// Every active track stopped; the capture must be finalized.
    case interrupted(String)
    /// One track stopped while another keeps recording.
    case trackFailed(String)
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
            return String(localized: "The selected macOS content is no longer available for capture.")
        case .alreadyCapturing:
            return String(localized: "A system-audio capture is already active.")
        case .notCapturing:
            return String(localized: "No system-audio capture is active.")
        case .missingMicrophoneDestination:
            return String(localized: "The dual-source capture has no microphone staging destination.")
        case .noAudioSamples(let source):
            return String(localized: "No readable \(source) audio samples were received.")
        case .writer(let message):
            return String(localized: "Bardo could not write captured audio: \(message)")
        case .screenCapture(let message):
            return String(localized: "ScreenCaptureKit could not continue: \(message)")
        }
    }
}
