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

    private init() {
        self.filter = nil
        self.testIdentifier = nil
    }

    /// Everything the Mac plays, for backends that need no picked content.
    static let entireSystem = SystemContentSelection()
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

    /// Live loudness of each track while capturing, for the recorder's waveform.
    var systemMeter: LiveAudioMeter? { get }
    var microphoneMeter: LiveAudioMeter? { get }
    /// The microphone being recorded, while capturing with one.
    var microphoneName: String? { get }
    var microphoneDeviceUID: String? { get }
    /// Records another microphone from now on, without stopping.
    func switchMicrophone(toDeviceUID uid: String) throws

    /// Whether `pause()` and `resume()` work: the capture keeps running and drops what it
    /// hears in between, and the files continue as if there had been no pause.
    var supportsPause: Bool { get }
    func pause()
    func resume()

    /// Whether the microphone can be silenced while the Mac's audio keeps recording.
    var supportsMicrophoneMute: Bool { get }
    func setMicrophoneMuted(_ muted: Bool)
}

extension SystemAudioCapturing {
    var systemMeter: LiveAudioMeter? { nil }
    var microphoneMeter: LiveAudioMeter? { nil }
    var microphoneName: String? { nil }
    var microphoneDeviceUID: String? { nil }
    func switchMicrophone(toDeviceUID uid: String) throws {
        throw SystemAudioCaptureError.notCapturing
    }
    var supportsPause: Bool { false }
    func pause() {}
    func resume() {}
    var supportsMicrophoneMute: Bool { false }
    func setMicrophoneMuted(_ muted: Bool) {}
}

enum SystemAudioCaptureError: Error, LocalizedError, Equatable, Sendable {
    case invalidSelection
    case alreadyCapturing
    case notCapturing
    case missingMicrophoneDestination
    case noAudioSamples(String)
    case writer(String)
    case screenCapture(String)
    case systemAudio(String)

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
        case .systemAudio(let message):
            return message
        }
    }
}
