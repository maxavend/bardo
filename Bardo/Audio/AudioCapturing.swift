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
            return "A microphone recording is already active."
        case .noInputDevice:
            return "No microphone input is currently available."
        case .preparationFailed:
            return "The microphone recorder could not prepare its output file."
        case .startFailed:
            return "The microphone recorder could not start capturing audio."
        case .recorderInitialization(let description):
            return "The microphone recorder could not be created: \(description)"
        }
    }
}

@MainActor
protocol AudioCapturing: AnyObject {
    var fileExtension: String { get }
    var currentTime: TimeInterval { get }
    var inputDisplayName: String? { get }
    var isRecording: Bool { get }
    var eventHandler: ((AudioCaptureBackendEvent) -> Void)? { get set }

    func start(to url: URL) throws
    func stop()
}
