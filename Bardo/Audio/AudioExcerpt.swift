@preconcurrency import AVFAudio
import Foundation

/// A short stretch of a recording, for listening before it is compressed. The excerpt
/// is decoded to uncompressed CAF, so it sounds exactly like the original and can be
/// encoded at any quality with `AudioFileTranscoder`.
enum AudioExcerpt {
    /// How long a preview lasts.
    static let length: TimeInterval = 20

    /// Where a preview starts: a quarter in, past greetings and setup, but always
    /// leaving a full excerpt when the recording is long enough.
    static func start(forDuration duration: TimeInterval, length: TimeInterval = length) -> TimeInterval {
        guard duration.isFinite, duration > length else { return 0 }
        return min(duration * 0.25, duration - length)
    }

    /// Writes `[start, start + length)` of `sourceURL` to `destinationURL` as CAF.
    /// Returns how long the excerpt lasts, shorter when the recording ends first.
    @discardableResult
    static func write(
        from sourceURL: URL,
        start: TimeInterval,
        length: TimeInterval = length,
        to destinationURL: URL
    ) throws -> TimeInterval {
        try? FileManager.default.removeItem(at: destinationURL)
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        let firstFrame = min(input.length, AVAudioFramePosition((max(0, start) * format.sampleRate).rounded()))
        let endFrame = min(input.length, firstFrame + AVAudioFramePosition((max(0, length) * format.sampleRate).rounded()))
        guard endFrame > firstFrame else { throw AudioTranscodingError.couldNotConvert }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AudioFileTranscoder.framesPerChunk) else {
            throw AudioTranscodingError.couldNotAllocateBuffer
        }
        do {
            let output = try AVAudioFile(
                forWriting: destinationURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            input.framePosition = firstFrame
            while input.framePosition < endFrame {
                let remaining = AVAudioFrameCount(endFrame - input.framePosition)
                try input.read(into: buffer, frameCount: min(AudioFileTranscoder.framesPerChunk, remaining))
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
            output.close()
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        return Double(endFrame - firstFrame) / format.sampleRate
    }
}
