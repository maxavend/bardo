import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

final class ScreenCaptureKitAudioBackend: NSObject, SystemAudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @MainActor var eventHandler: ((SystemAudioCaptureBackendEvent) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.maxavend.bardo.system-audio.samples")
    private let processor = SystemAudioSampleProcessor()

    @MainActor private var stream: SCStream?
    @MainActor private var isStopping = false

    @MainActor
    var currentTime: TimeInterval {
        processor.elapsedTime
    }

    static func makeConfiguration(includeMicrophone: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = includeMicrophone
        if includeMicrophone {
            configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        // ScreenCaptureKit still streams selected visual content internally, but Bardo does
        // not register a .screen output. Keep visual work minimal because no video is stored.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 3
        return configuration
    }

    @MainActor
    func start(
        selection: SystemContentSelection,
        includeMicrophone: Bool,
        systemURL: URL,
        microphoneURL: URL?
    ) async throws {
        guard stream == nil else { throw SystemAudioCaptureError.alreadyCapturing }
        guard let filter = selection.filter else { throw SystemAudioCaptureError.invalidSelection }
        if includeMicrophone && microphoneURL == nil {
            throw SystemAudioCaptureError.missingMicrophoneDestination
        }

        processor.configure(systemURL: systemURL, microphoneURL: includeMicrophone ? microphoneURL : nil)
        let stream = SCStream(
            filter: filter,
            configuration: Self.makeConfiguration(includeMicrophone: includeMicrophone),
            delegate: self
        )

        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            if includeMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            try await startCapture(stream)
            self.stream = stream
        } catch {
            processor.reset()
            throw SystemAudioCaptureError.screenCapture(error.localizedDescription)
        }
    }

    @MainActor
    func update(selection: SystemContentSelection) async throws {
        guard let stream else { throw SystemAudioCaptureError.notCapturing }
        guard let filter = selection.filter else { throw SystemAudioCaptureError.invalidSelection }
        do {
            try await updateContentFilter(stream, filter: filter)
        } catch {
            throw SystemAudioCaptureError.screenCapture(error.localizedDescription)
        }
    }

    @MainActor
    func stop() async -> SystemAudioCaptureResult {
        guard let stream else {
            return SystemAudioCaptureResult(
                systemTrack: nil,
                microphoneTrack: nil,
                systemError: SystemAudioCaptureError.notCapturing.localizedDescription,
                microphoneError: nil,
                streamStopError: nil
            )
        }

        isStopping = true
        var stopError: String?
        do {
            try await stopCapture(stream)
        } catch {
            stopError = error.localizedDescription
        }
        self.stream = nil

        // Drain every callback already enqueued before finalizing writers.
        sampleQueue.sync { }
        let result = await processor.finish(streamStopError: stopError)
        processor.reset()
        isStopping = false
        return result
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio || type == .microphone else { return }
        let event: SystemAudioCaptureBackendEvent
        switch processor.append(sampleBuffer, type: type) {
        case .recording:
            return
        case .trackFailed(let message):
            event = .trackFailed(message)
        case .allTracksFailed(let message):
            event = .interrupted(message)
        }
        Task { @MainActor [weak self] in
            self?.eventHandler?(event)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, !self.isStopping, self.stream != nil else { return }
            self.eventHandler?(.interrupted(message))
        }
    }

    @MainActor
    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture(
                completionHandler: ScreenCaptureKitCompletionBridge.handler(for: continuation)
            )
        }
    }

    @MainActor
    private func updateContentFilter(_ stream: SCStream, filter: SCContentFilter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.updateContentFilter(
                filter,
                completionHandler: ScreenCaptureKitCompletionBridge.handler(for: continuation)
            )
        }
    }

    @MainActor
    private func stopCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture(
                completionHandler: ScreenCaptureKitCompletionBridge.handler(for: continuation)
            )
        }
    }
}

/// ScreenCaptureKit invokes its completion handlers on framework-owned queues. Creating
/// these handlers outside MainActor isolation prevents Swift 6 runtime executor checks from
/// trapping when the framework calls them off the main queue. The only value they touch is
/// a Sendable continuation; SCStream itself remains confined to MainActor in the backend.
enum ScreenCaptureKitCompletionBridge {
    nonisolated static func handler(
        for continuation: CheckedContinuation<Void, Error>
    ) -> @Sendable ((any Error)?) -> Void {
        { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ())
            }
        }
    }
}

final class SystemAudioSampleProcessor: @unchecked Sendable {
    enum AppendResult: Equatable, Sendable {
        case recording
        /// One track stopped; the other configured track keeps recording.
        case trackFailed(String)
        /// No configured track can record anymore.
        case allTracksFailed(String)
    }

    private let lock = NSLock()
    private var systemWriter: CMSampleBufferAudioWriter?
    private var microphoneWriter: CMSampleBufferAudioWriter?

    var elapsedTime: TimeInterval {
        let writers = lock.bardoWithLock { (systemWriter, microphoneWriter) }
        return max(writers.0?.elapsedTime ?? 0, writers.1?.elapsedTime ?? 0)
    }

    func configure(systemURL: URL, microphoneURL: URL?) {
        lock.bardoWithLock {
            systemWriter = CMSampleBufferAudioWriter(outputURL: systemURL, channelCount: 2, bitRate: 128_000)
            microphoneWriter = microphoneURL.map {
                CMSampleBufferAudioWriter(outputURL: $0, channelCount: 1, bitRate: 96_000)
            }
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) -> AppendResult {
        let writers = lock.bardoWithLock { (systemWriter, microphoneWriter) }
        let writer: CMSampleBufferAudioWriter?
        let sourceName: String
        switch type {
        case .audio:
            writer = writers.0
            sourceName = String(localized: "System audio")
        case .microphone:
            writer = writers.1
            sourceName = String(localized: "Microphone")
        default:
            return .recording
        }

        guard let writer,
              case .failed(let newlyFailed, let message) = writer.append(sampleBuffer),
              newlyFailed else {
            return .recording
        }

        let detail = String(localized: "\(sourceName) stopped recording: \(message)")
        let configured = [writers.0, writers.1].compactMap { $0 }
        return configured.allSatisfy(\.hasFailed) ? .allTracksFailed(detail) : .trackFailed(detail)
    }

    func finish(streamStopError: String?) async -> SystemAudioCaptureResult {
        let writers = lock.bardoWithLock { (systemWriter, microphoneWriter) }

        var systemTrack: CapturedAudioTrackTiming?
        var microphoneTrack: CapturedAudioTrackTiming?
        var systemError: String?
        var microphoneError: String?

        if let writer = writers.0 {
            do {
                systemTrack = try await writer.finish(sourceName: String(localized: "system"))
            } catch {
                systemError = error.localizedDescription
            }
        }

        if let writer = writers.1 {
            do {
                microphoneTrack = try await writer.finish(sourceName: String(localized: "microphone"))
            } catch {
                microphoneError = error.localizedDescription
            }
        }

        return SystemAudioCaptureResult(
            systemTrack: systemTrack,
            microphoneTrack: microphoneTrack,
            systemError: systemError,
            microphoneError: microphoneError,
            streamStopError: streamStopError
        )
    }

    func reset() {
        lock.bardoWithLock {
            systemWriter = nil
            microphoneWriter = nil
        }
    }
}
