import Foundation

enum AudioCaptureBackendEvent: Equatable, Sendable {
    case interrupted(String)
}

enum AudioCaptureBackendError: Error, LocalizedError, Equatable, Sendable {
    case alreadyRecording
    case noInputDevice
    case preparationFailed
    case startFailed
    case recorderInitialization(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return String(localized: "A microphone recording is already active.")
        case .noInputDevice:
            return String(localized: "No microphone input is currently available.")
        case .preparationFailed:
            return String(localized: "The microphone recorder could not prepare its output file.")
        case .startFailed:
            return String(localized: "The microphone recorder could not start capturing audio.")
        case .recorderInitialization(let description):
            return String(localized: "The microphone recorder could not be created: \(description)")
        }
    }
}

@MainActor
protocol AudioCapturing: AnyObject {
    var fileExtension: String { get }
    var currentTime: TimeInterval { get }
    var inputDisplayName: String? { get }
    var inputLevel: Double { get }
    var isRecording: Bool { get }
    var eventHandler: ((AudioCaptureBackendEvent) -> Void)? { get set }

    func start(to url: URL) throws
    func pause()
    func resume()
    func stop()
}

extension AudioCapturing {
    var inputLevel: Double { 0 }
    func pause() {}
    func resume() {}
}
