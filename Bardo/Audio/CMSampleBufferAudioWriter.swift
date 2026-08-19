import AVFoundation
import CoreMedia
import Foundation

final class CMSampleBufferAudioWriter: @unchecked Sendable {
    private let outputURL: URL
    private let channelCount: Int
    private let bitRate: Int
    private let lock = NSLock()

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastEndPTS: CMTime?
    private var terminalError: Error?

    init(outputURL: URL, channelCount: Int, bitRate: Int = 128_000) {
        self.outputURL = outputURL
        self.channelCount = channelCount
        self.bitRate = bitRate
    }

    var elapsedTime: TimeInterval {
        lock.bardoWithLock {
            guard let firstPTS, let lastEndPTS else { return 0 }
            let value = CMTimeGetSeconds(CMTimeSubtract(lastEndPTS, firstPTS))
            return value.isFinite ? max(0, value) : 0
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if let terminalError { throw terminalError }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, !pts.isIndefinite else { return }

        if writer == nil {
            try prepareWriter(startingAt: pts)
        }

        guard let writer, let input else {
            throw SystemAudioCaptureError.writer("The audio writer was not prepared.")
        }
        guard writer.status == .writing else {
            let error = writer.error ?? SystemAudioCaptureError.writer("The audio writer left the writing state.")
            terminalError = error
            throw error
        }
        guard input.isReadyForMoreMediaData else {
            let error = SystemAudioCaptureError.writer("Realtime audio writer backpressure would have dropped a sample.")
            terminalError = error
            throw error
        }
        guard input.append(sampleBuffer) else {
            let error = writer.error ?? SystemAudioCaptureError.writer("AVAssetWriter rejected an audio sample.")
            terminalError = error
            throw error
        }

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let endPTS = duration.isValid && !duration.isIndefinite && CMTimeCompare(duration, .zero) > 0
            ? CMTimeAdd(pts, duration)
            : pts

        lock.bardoWithLock {
            if firstPTS == nil { firstPTS = pts }
            if let current = lastEndPTS {
                lastEndPTS = maxCMTime(current, endPTS)
            } else {
                lastEndPTS = endPTS
            }
        }
    }

    func fail(_ error: Error) {
        terminalError = error
    }

    func finish(sourceName: String) async throws -> CapturedAudioTrackTiming {
        if let terminalError { throw terminalError }
        guard let writer, let input else {
            throw SystemAudioCaptureError.noAudioSamples(sourceName)
        }
        guard writer.status == .writing else {
            throw writer.error ?? SystemAudioCaptureError.writer("The \(sourceName) writer was not active at finalization.")
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? SystemAudioCaptureError.writer("The \(sourceName) writer could not finalize its M4A file.")
        }

        return try lock.bardoWithLock {
            guard let firstPTS, let lastEndPTS else {
                throw SystemAudioCaptureError.noAudioSamples(sourceName)
            }
            return CapturedAudioTrackTiming(
                firstPresentationTime: CMTimeGetSeconds(firstPTS),
                lastPresentationTime: CMTimeGetSeconds(lastEndPTS)
            )
        }
    }

    private func prepareWriter(startingAt pts: CMTime) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw SystemAudioCaptureError.writer("AVAssetWriter cannot add the requested audio input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? SystemAudioCaptureError.writer("AVAssetWriter could not start writing.")
        }
        writer.startSession(atSourceTime: pts)

        self.writer = writer
        self.input = input
        lock.bardoWithLock {
            firstPTS = pts
            lastEndPTS = pts
        }
    }

    private func maxCMTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) >= 0 ? lhs : rhs
    }
}

extension NSLock {
    func bardoWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
