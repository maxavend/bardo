import AVFoundation
import CoreMedia
import Foundation

/// Writes one realtime audio track to a fragmented M4A file.
///
/// Fragments are flushed every second, so a crash, force quit or power loss leaves the
/// audio captured up to the last fragment readable instead of an index-less file. A
/// momentary encoder backlog is absorbed by a bounded queue rather than ending the track.
final class CMSampleBufferAudioWriter: @unchecked Sendable {
    enum AppendOutcome: Equatable, Sendable {
        case accepted
        case ignored
        /// The track can no longer accept audio. `newlyFailed` is true only for the
        /// sample that discovered the failure, so callers can report it exactly once.
        case failed(newlyFailed: Bool, message: String)
    }

    static let fragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    /// About thirty seconds of ScreenCaptureKit audio buffers (roughly 11 MB of stereo
    /// Float32), enough to ride out an encoder stall on a heavily loaded Mac.
    static let defaultMaximumPendingBuffers = 1_500
    static let finalizationDrainTimeout: Duration = .seconds(5)

    private let outputURL: URL
    private let channelCount: Int
    private let bitRate: Int
    private let maximumPendingBuffers: Int
    /// Tests replace the encoder's readiness to exercise the backlog deterministically.
    private let isReadyForMoreData: @Sendable (AVAssetWriterInput) -> Bool
    private let lock = NSLock()

    // Mutable state is only touched while holding `lock`.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var pending: [CMSampleBuffer] = []
    private var firstPTS: CMTime?
    private var lastEndPTS: CMTime?
    private var failure: Error?
    private var droppedBufferCount = 0
    private var isFinishing = false

    init(
        outputURL: URL,
        channelCount: Int,
        bitRate: Int = 128_000,
        maximumPendingBuffers: Int = CMSampleBufferAudioWriter.defaultMaximumPendingBuffers,
        isReadyForMoreData: @escaping @Sendable (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData }
    ) {
        self.outputURL = outputURL
        self.channelCount = channelCount
        self.bitRate = bitRate
        self.maximumPendingBuffers = max(1, maximumPendingBuffers)
        self.isReadyForMoreData = isReadyForMoreData
    }

    var elapsedTime: TimeInterval {
        lock.bardoWithLock {
            guard let firstPTS, let lastEndPTS else { return 0 }
            let value = CMTimeGetSeconds(CMTimeSubtract(lastEndPTS, firstPTS))
            return value.isFinite ? max(0, value) : 0
        }
    }

    var hasFailed: Bool {
        lock.bardoWithLock { failure != nil }
    }

    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) -> AppendOutcome {
        lock.bardoWithLock {
            guard !isFinishing else { return .ignored }
            if let failure {
                return .failed(newlyFailed: false, message: failure.localizedDescription)
            }
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return .ignored }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid, !pts.isIndefinite else { return .ignored }

            do {
                if writer == nil {
                    try prepareWriterLocked(startingAt: pts)
                }
                guard let writer, let input else {
                    throw SystemAudioCaptureError.writer(String(localized: "The audio writer was not prepared."))
                }
                guard writer.status == .writing else {
                    throw writer.error ?? SystemAudioCaptureError.writer(String(localized: "The audio writer left the writing state."))
                }

                try drainPendingLocked(input: input, writer: writer)
                if pending.isEmpty, isReadyForMoreData(input) {
                    try appendLocked(sampleBuffer, input: input, writer: writer)
                } else if pending.count < maximumPendingBuffers {
                    pending.append(sampleBuffer)
                } else {
                    droppedBufferCount += 1
                }
                return .accepted
            } catch {
                failure = error
                pending.removeAll()
                return .failed(newlyFailed: true, message: error.localizedDescription)
            }
        }
    }

    /// Finalizes the file. A track that failed mid-capture still returns its timing
    /// (with a warning) when audio was written, because its fragments remain readable.
    func finish(sourceName: String) async throws -> CapturedAudioTrackTiming {
        let state = lock.bardoWithLock {
            isFinishing = true
            return (writer, input, failure)
        }
        guard let writer = state.0, let input = state.1 else {
            throw state.2 ?? SystemAudioCaptureError.noAudioSamples(sourceName)
        }

        var finalizationError = state.2
        if finalizationError == nil, writer.status == .writing {
            await drainPendingForFinalization(input: input, writer: writer)
            // Draining can fail the writer; finishing a failed writer raises an exception.
            finalizationError = lock.bardoWithLock { failure }
        }
        if finalizationError == nil, writer.status == .writing {
            input.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            if writer.status != .completed {
                finalizationError = writer.error
                    ?? SystemAudioCaptureError.writer(String(localized: "The \(sourceName) writer could not finalize its M4A file."))
            }
        } else if finalizationError == nil {
            finalizationError = writer.error
                ?? SystemAudioCaptureError.writer(String(localized: "The \(sourceName) writer was not active at finalization."))
        }

        let snapshot = lock.bardoWithLock { (firstPTS, lastEndPTS, droppedBufferCount) }
        guard let first = snapshot.0,
              let last = snapshot.1,
              CMTimeCompare(last, first) > 0 else {
            throw finalizationError ?? SystemAudioCaptureError.noAudioSamples(sourceName)
        }

        var warnings: [String] = []
        if let finalizationError {
            warnings.append(String(localized: "The \(sourceName) track stopped early (\(finalizationError.localizedDescription)). Audio captured before that point was kept."))
        }
        if snapshot.2 > 0 {
            warnings.append(String(localized: "The \(sourceName) track skipped \(snapshot.2) short audio buffers while the Mac was busy."))
        }

        return CapturedAudioTrackTiming(
            firstPresentationTime: CMTimeGetSeconds(first),
            lastPresentationTime: CMTimeGetSeconds(last),
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }

    private func drainPendingForFinalization(input: AVAssetWriterInput, writer: AVAssetWriter) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.finalizationDrainTimeout)

        while true {
            let remaining: Int = lock.bardoWithLock {
                do {
                    try drainPendingLocked(input: input, writer: writer)
                } catch {
                    failure = error
                    pending.removeAll()
                }
                return pending.count
            }
            guard remaining > 0 else { return }
            guard clock.now < deadline else {
                lock.bardoWithLock {
                    droppedBufferCount += pending.count
                    pending.removeAll()
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func drainPendingLocked(input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        while !pending.isEmpty, isReadyForMoreData(input) {
            let next = pending.removeFirst()
            try appendLocked(next, input: input, writer: writer)
        }
    }

    private func appendLocked(
        _ sampleBuffer: CMSampleBuffer,
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws {
        guard input.append(sampleBuffer) else {
            throw writer.error ?? SystemAudioCaptureError.writer(String(localized: "AVAssetWriter rejected an audio sample."))
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let endPTS = duration.isValid && !duration.isIndefinite && CMTimeCompare(duration, .zero) > 0
            ? CMTimeAdd(pts, duration)
            : pts

        if firstPTS == nil { firstPTS = pts }
        if let current = lastEndPTS {
            lastEndPTS = CMTimeCompare(current, endPTS) >= 0 ? current : endPTS
        } else {
            lastEndPTS = endPTS
        }
    }

    private func prepareWriterLocked(startingAt pts: CMTime) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        writer.movieFragmentInterval = Self.fragmentInterval
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
            throw SystemAudioCaptureError.writer(String(localized: "AVAssetWriter cannot add the requested audio input."))
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? SystemAudioCaptureError.writer(String(localized: "AVAssetWriter could not start writing."))
        }
        writer.startSession(atSourceTime: pts)

        self.writer = writer
        self.input = input
    }
}

extension NSLock {
    func bardoWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
