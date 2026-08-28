import AVFAudio
import Foundation

@testable import Bardo

@MainActor
final class TestMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    var status: MicrophonePermissionState
    var requestResult: MicrophonePermissionState
    private(set) var requestCount = 0

    init(
        status: MicrophonePermissionState,
        requestResult: MicrophonePermissionState? = nil
    ) {
        self.status = status
        self.requestResult = requestResult ?? status
    }

    func currentStatus() -> MicrophonePermissionState {
        status
    }

    func requestAccess() async -> MicrophonePermissionState {
        requestCount += 1
        status = requestResult
        return requestResult
    }
}

@MainActor
final class SuspendingMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    private(set) var status: MicrophonePermissionState = .notDetermined
    private var continuation: CheckedContinuation<MicrophonePermissionState, Never>?

    func currentStatus() -> MicrophonePermissionState {
        status
    }

    func requestAccess() async -> MicrophonePermissionState {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ state: MicrophonePermissionState) {
        status = state
        continuation?.resume(returning: state)
        continuation = nil
    }
}

@MainActor
final class IncrementalTestCaptureBackend: AudioCapturing {
    var fileExtension: String { "wav" }
    var currentTime: TimeInterval = 0
    var inputDisplayName: String? = "CI Test Microphone"
    var isRecording = false
    var eventHandler: ((AudioCaptureBackendEvent) -> Void)?

    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var lastURL: URL?

    private let sampleRate: Double = 8_000
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var isPaused = false

    func start(to url: URL) throws {
        startCount += 1
        if let startError {
            throw startError
        }
        guard !isRecording, file == nil else {
            throw AudioCaptureBackendError.alreadyRecording
        }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw AudioCaptureBackendError.recorderInitialization("Could not create the test audio format.")
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = file
        self.format = format
        lastURL = url
        isRecording = true
        isPaused = false
        currentTime = 0
        try writeChunk(duration: 0.25)
    }

    func pause() throws {
        guard isRecording, !isPaused else { throw AudioCaptureBackendError.invalidPauseState }
        pauseCount += 1
        isPaused = true
        isRecording = false
    }

    func resume() throws {
        guard file != nil, isPaused else { throw AudioCaptureBackendError.invalidPauseState }
        resumeCount += 1
        isPaused = false
        isRecording = true
        try writeChunk(duration: 0.1)
    }

    func stop() {
        guard isRecording || isPaused || file != nil else { return }
        stopCount += 1
        if isRecording {
            try? writeChunk(duration: 0.25)
        }
        isRecording = false
        isPaused = false
        file?.close()
        file = nil
        format = nil
    }

    func simulateInterruption(_ message: String) {
        guard isRecording || isPaused else { return }
        if isRecording {
            try? writeChunk(duration: 0.1)
        }
        isRecording = false
        isPaused = false
        file?.close()
        file = nil
        format = nil
        eventHandler?(.interrupted(message))
    }

    private func writeChunk(duration: TimeInterval) throws {
        guard let file, let format else { return }
        let frameCount = AVAudioFrameCount((sampleRate * duration).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else {
            throw AudioCaptureBackendError.recorderInitialization("Could not allocate a test audio buffer.")
        }

        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            channels[0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / sampleRate) * 0.05)
        }
        try file.write(from: buffer)
        currentTime += duration
    }
}
