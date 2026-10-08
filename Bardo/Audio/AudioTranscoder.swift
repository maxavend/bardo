@preconcurrency import AVFAudio
import Foundation

protocol AudioTranscoding: Sendable {
    /// Encodes `sourceURL` as a compact AAC M4A file at `destinationURL`.
    func transcodeToCompactM4A(from sourceURL: URL, to destinationURL: URL) async throws
}

enum AudioTranscodingError: Error, LocalizedError, Equatable, Sendable {
    case couldNotAllocateBuffer
    case incompleteOutput(expected: TimeInterval, actual: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .couldNotAllocateBuffer:
            return "Bardo could not allocate an audio conversion buffer."
        case .incompleteOutput(let expected, let actual):
            return String(format: "The compressed audio is shorter than the original (%.1f s of %.1f s).", actual, expected)
        }
    }
}

/// Microphone captures are staged as crash-safe linear PCM and compressed once the
/// recording ends. Conversion streams in fixed-size chunks so memory stays bounded for
/// long recordings.
struct AACAudioTranscoder: AudioTranscoding {
    static let framesPerChunk: AVAudioFrameCount = 32_768

    func transcodeToCompactM4A(from sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.encode(from: sourceURL, to: destinationURL)
        }.value
    }

    static func encode(from sourceURL: URL, to destinationURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try encodeChunks(from: sourceURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func encodeChunks(from sourceURL: URL, to destinationURL: URL) throws {
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        // AAC bit-rate limits depend on the sample rate; only pin the conversation
        // bit rate at the rates Bardo records, and let the encoder pick otherwise.
        if format.sampleRate >= 44_100 {
            settings[AVEncoderBitRateKey] = format.channelCount == 1 ? 96_000 : 128_000
        }

        let expectedDuration = Double(input.length) / format.sampleRate
        do {
            let output = try AVAudioFile(
                forWriting: destinationURL,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk) else {
                throw AudioTranscodingError.couldNotAllocateBuffer
            }

            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: framesPerChunk)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
            output.close()
        }

        let encoded = try AVAudioFile(forReading: destinationURL)
        let actualDuration = Double(encoded.length) / encoded.processingFormat.sampleRate
        // AAC priming and packet rounding change the length by a few milliseconds only.
        guard actualDuration >= expectedDuration - 0.25 else {
            throw AudioTranscodingError.incompleteOutput(expected: expectedDuration, actual: actualDuration)
        }
    }
}
