import Foundation
@testable import Bardo

@MainActor
final class FakeSystemContentPicker: SystemContentSelecting {
    var eventHandler: ((SystemContentSelectionEvent) -> Void)?
    private(set) var presentCount = 0
    private(set) var deactivateCount = 0

    func present() {
        presentCount += 1
    }

    func deactivate() {
        deactivateCount += 1
    }

    func selectInitial(_ identifier: String = "test-content") {
        eventHandler?(.selected(SystemContentSelection(testIdentifier: identifier), isUpdate: false))
    }

    func updateSelection(_ identifier: String = "updated-content") {
        eventHandler?(.selected(SystemContentSelection(testIdentifier: identifier), isUpdate: true))
    }

    func cancelInitial() {
        eventHandler?(.cancelled(isUpdate: false))
    }

    func cancelUpdate() {
        eventHandler?(.cancelled(isUpdate: true))
    }

    func fail(_ message: String) {
        eventHandler?(.failed(message))
    }
}

@MainActor
final class FakeSystemAudioCaptureBackend: SystemAudioCapturing {
    var eventHandler: ((SystemAudioCaptureBackendEvent) -> Void)?
    var currentTime: TimeInterval = 12.5
    var systemDuration: TimeInterval = 0.45
    var microphoneDuration: TimeInterval = 0.40
    var systemFirstPTS: TimeInterval = 100
    var microphoneFirstPTS: TimeInterval = 100.05
    var produceSystem = true
    var produceMicrophone = true
    var systemError: String?
    var microphoneError: String?
    var streamStopError: String?
    var startError: Error?
    var pauseError: Error?
    var resumeError: Error?

    private(set) var startCount = 0
    private(set) var updateCount = 0
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var lastIncludeMicrophone = false
    private(set) var lastSystemURL: URL?
    private(set) var lastMicrophoneURL: URL?
    private(set) var isPaused = false

    func start(
        selection: SystemContentSelection,
        includeMicrophone: Bool,
        systemURL: URL,
        microphoneURL: URL?
    ) async throws {
        if let startError { throw startError }
        startCount += 1
        lastIncludeMicrophone = includeMicrophone
        lastSystemURL = systemURL
        lastMicrophoneURL = microphoneURL
        isPaused = false

        if produceSystem {
            try AudioTestFixture.makeM4A(
                at: systemURL,
                sampleRate: 48_000,
                channelCount: 2,
                duration: systemDuration
            )
        }
        if includeMicrophone, produceMicrophone, let microphoneURL {
            try AudioTestFixture.makeM4A(
                at: microphoneURL,
                sampleRate: 48_000,
                channelCount: 1,
                duration: microphoneDuration
            )
        }
    }

    func update(selection: SystemContentSelection) async throws {
        guard !isPaused else { throw SystemAudioCaptureError.invalidPauseState }
        updateCount += 1
    }

    func pause() async throws {
        if let pauseError { throw pauseError }
        guard !isPaused else { throw SystemAudioCaptureError.invalidPauseState }
        pauseCount += 1
        isPaused = true
    }

    func resume() async throws {
        if let resumeError { throw resumeError }
        guard isPaused else { throw SystemAudioCaptureError.invalidPauseState }
        resumeCount += 1
        isPaused = false
    }

    func stop() async -> SystemAudioCaptureResult {
        stopCount += 1
        isPaused = false
        return SystemAudioCaptureResult(
            systemTrack: produceSystem && systemError == nil
                ? CapturedAudioTrackTiming(
                    firstPresentationTime: systemFirstPTS,
                    lastPresentationTime: systemFirstPTS + systemDuration
                )
                : nil,
            microphoneTrack: lastIncludeMicrophone && produceMicrophone && microphoneError == nil
                ? CapturedAudioTrackTiming(
                    firstPresentationTime: microphoneFirstPTS,
                    lastPresentationTime: microphoneFirstPTS + microphoneDuration
                )
                : nil,
            systemError: systemError,
            microphoneError: microphoneError,
            streamStopError: streamStopError
        )
    }

    func interrupt(_ message: String) {
        eventHandler?(.interrupted(message))
    }
}

struct FailingConversationMixer: ConversationMixing {
    let message: String

    func makeMix(
        systemURL: URL,
        microphoneURL: URL,
        systemOffset: TimeInterval,
        microphoneOffset: TimeInterval,
        outputURL: URL
    ) async throws -> AudioMetadata {
        throw ConversationMixError.exportFailed(message)
    }
}
