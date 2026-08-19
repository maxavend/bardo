import CoreMedia
import Foundation
import ScreenCaptureKit

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
            try await stream.startCapture()
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
            try await stream.updateContentFilter(filter)
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
            try await stream.stopCapture()
        } catch {
            stopError = error.localizedDescription
        }
        self.stream = nil

        // Drain every sample callback that was already enqueued before finalizing writers.
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
        do {
            try processor.append(sampleBuffer, type: type)
        } catch {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.eventHandler?(.interrupted(message))
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, !self.isStopping, self.stream != nil else { return }
            self.eventHandler?(.interrupted(message))
        }
    }
}

private final class SystemAudioSampleProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var systemWriter: CMSampleBufferAudioWriter?
    private var microphoneWriter: CMSampleBufferAudioWriter?
    private var systemFailure: String?
    private var microphoneFailure: String?

    var elapsedTime: TimeInterval {
        lock.bardoWithLock {
            max(systemWriter?.elapsedTime ?? 0, microphoneWriter?.elapsedTime ?? 0)
        }
    }

    func configure(systemURL: URL, microphoneURL: URL?) {
        lock.bardoWithLock {
            systemWriter = CMSampleBufferAudioWriter(outputURL: systemURL, channelCount: 2, bitRate: 128_000)
            microphoneWriter = microphoneURL.map {
                CMSampleBufferAudioWriter(outputURL: $0, channelCount: 1, bitRate: 96_000)
            }
            systemFailure = nil
            microphoneFailure = nil
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) throws {
        let writer: CMSampleBufferAudioWriter?
        lock.lock()
        if type == .audio {
            writer = systemWriter
        } else if type == .microphone {
            writer = microphoneWriter
        } else {
            writer = nil
        }
        lock.unlock()

        guard let writer else { return }
        do {
            try writer.append(sampleBuffer)
        } catch {
            lock.bardoWithLock {
                if type == .audio {
                    systemFailure = error.localizedDescription
                } else if type == .microphone {
                    microphoneFailure = error.localizedDescription
                }
            }
            throw error
        }
    }

    func finish(streamStopError: String?) async -> SystemAudioCaptureResult {
        let snapshot = lock.bardoWithLock {
            (systemWriter, microphoneWriter, systemFailure, microphoneFailure)
        }

        var systemTrack: CapturedAudioTrackTiming?
        var microphoneTrack: CapturedAudioTrackTiming?
        var systemError = snapshot.2
        var microphoneError = snapshot.3

        if systemError == nil, let writer = snapshot.0 {
            do {
                systemTrack = try await writer.finish(sourceName: "system")
            } catch {
                systemError = error.localizedDescription
            }
        }

        if microphoneError == nil, let writer = snapshot.1 {
            do {
                microphoneTrack = try await writer.finish(sourceName: "microphone")
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
            systemFailure = nil
            microphoneFailure = nil
        }
    }
}
