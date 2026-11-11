@preconcurrency import AVFAudio
import Foundation

protocol AudioTranscoding: Sendable {
    /// Writes `sourceURL` at `destinationURL` in `encoding`, keeping its channels.
    func transcode(from sourceURL: URL, to destinationURL: URL, encoding: AudioEncoding) async throws
}

enum AudioTranscodingError: Error, LocalizedError, Equatable, Sendable {
    case couldNotAllocateBuffer
    case couldNotConvert
    case incompleteOutput(expected: TimeInterval, actual: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .couldNotAllocateBuffer:
            return String(localized: "Bardo could not allocate an audio conversion buffer.")
        case .couldNotConvert:
            return "Bardo no pudo convertir el audio."
        case .incompleteOutput(let expected, let actual):
            return String(format: "The compressed audio is shorter than the original (%.1f s of %.1f s).", actual, expected)
        }
    }
}

/// Re-encodes a finished recording in the chosen quality and format: microphone captures
/// staged as crash-safe linear PCM, a meeting's tracks once it ends, and recordings
/// compressed later. Conversion streams in fixed-size chunks so memory stays bounded for
/// long recordings, and the result must last as long as the original.
struct AudioFileTranscoder: AudioTranscoding {
    static let framesPerChunk: AVAudioFrameCount = 32_768

    func transcode(from sourceURL: URL, to destinationURL: URL, encoding: AudioEncoding) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.encode(from: sourceURL, to: destinationURL, encoding: encoding)
        }.value
    }

    static func encode(from sourceURL: URL, to destinationURL: URL, encoding: AudioEncoding) throws {
        try encode(from: sourceURL, to: destinationURL) { input in
            // Below the rates Bardo records, keep the source's rate and let the encoder
            // choose the AAC bit rate.
            var settings = encoding.outputSettings(channels: Int(input.channelCount))
            if input.sampleRate < encoding.preset.sampleRate {
                settings[AVSampleRateKey] = input.sampleRate
                settings.removeValue(forKey: AVEncoderBitRateKey)
            }
            return settings
        }
    }

    static func encode(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: ((TimeInterval) -> Void)? = nil,
        settings: (AVAudioFormat) -> [String: Any]
    ) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try encodeChunks(from: sourceURL, to: destinationURL, progress: progress, settings: settings)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func encodeChunks(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: ((TimeInterval) -> Void)?,
        settings: (AVAudioFormat) -> [String: Any]
    ) throws {
        let input = try AVAudioFile(forReading: sourceURL)
        let inputFormat = input.processingFormat
        let expectedDuration = Double(input.length) / inputFormat.sampleRate
        var nextUpdate = ContinuousClock.now
        func reportProgress() {
            guard let progress else { return }
            let now = ContinuousClock.now
            guard now >= nextUpdate else { return }
            nextUpdate = now + .milliseconds(250)
            progress(Double(input.framePosition) / inputFormat.sampleRate)
        }

        do {
            let output = try AVAudioFile(
                forWriting: destinationURL,
                settings: settings(inputFormat),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let outputFormat = output.processingFormat
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerChunk) else {
                throw AudioTranscodingError.couldNotAllocateBuffer
            }

            if inputFormat == outputFormat {
                while input.framePosition < input.length {
                    try input.read(into: inputBuffer, frameCount: framesPerChunk)
                    guard inputBuffer.frameLength > 0 else { break }
                    try output.write(from: inputBuffer)
                    reportProgress()
                }
            } else {
                try convert(input, into: output, from: inputBuffer, onChunk: reportProgress)
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

    /// Resamples while writing, when the quality records fewer samples per second.
    private static func convert(
        _ input: AVAudioFile,
        into output: AVAudioFile,
        from inputBuffer: AVAudioPCMBuffer,
        onChunk: () -> Void
    ) throws {
        let inputFormat = input.processingFormat
        let outputFormat = output.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioTranscodingError.couldNotConvert
        }
        if outputFormat.channelCount < inputFormat.channelCount {
            converter.downmix = true
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(framesPerChunk) * ratio) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioTranscodingError.couldNotAllocateBuffer
        }

        var readError: Error?
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard input.framePosition < input.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inputBuffer, frameCount: framesPerChunk)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard inputBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? AudioTranscodingError.couldNotConvert }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
                onChunk()
            }
            if status == .endOfStream || (status == .inputRanDry && outputBuffer.frameLength == 0) { break }
        }
    }
}
