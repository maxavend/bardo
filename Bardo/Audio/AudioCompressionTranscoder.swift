import AVFAudio
import Foundation

enum AudioCompressionInput: Hashable, Sendable {
    struct Track: Hashable, Sendable {
        let url: URL
        let offset: TimeInterval
        let duration: TimeInterval
    }

    case file(URL, duration: TimeInterval)
    case mix([Track], duration: TimeInterval)

    var duration: TimeInterval {
        switch self {
        case .file(_, let duration), .mix(_, let duration): duration
        }
    }
}

enum AudioCompressionTranscoder {
    private static let progressKey = "audio_time="

    enum Failure: LocalizedError {
        case missingFFmpeg
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingFFmpeg: "Este ajuste requiere FFmpeg (brew install ffmpeg)."
            case .failed(let detail): "FFmpeg no pudo convertir el audio. \(detail)"
            }
        }
    }

    static var ffmpegURL: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func encode(
        from source: URL,
        to destination: URL,
        using encoding: AudioCompressionEncoding,
        progress: (@Sendable (TimeInterval) -> Void)? = nil
    ) async throws {
        try await encode(input: .file(source, duration: 0), to: destination, using: encoding, progress: progress)
    }

    static func encode(
        input: AudioCompressionInput,
        to destination: URL,
        using encoding: AudioCompressionEncoding,
        progress: (@Sendable (TimeInterval) -> Void)? = nil
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            if case .file(let source, _) = input,
               encoding.format == .aac, !encoding.requiresFFmpeg, ffmpegURL == nil {
                try AudioFileTranscoder.encode(from: source, to: destination, progress: progress) { _ in
                    [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: encoding.sampleRate,
                        AVNumberOfChannelsKey: encoding.channels.rawValue,
                        AVEncoderBitRateKey: encoding.bitsPerSecond,
                        AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]
                }
            } else {
                let options = [
                    "-ac", String(encoding.channels.rawValue),
                    "-ar", String(encoding.sampleRate),
                    "-b:a", String(encoding.bitsPerSecond)
                ] + codecOptions(for: encoding)
                do {
                    try convert(input: input, to: destination, options: options, progress: progress)
                } catch Failure.failed(let detail) where detail.contains("Unrecognized option 'stats_enc_post'") {
                    // Keep encoding available on installations that predate packet statistics.
                    try convert(input: input, to: destination, options: options)
                }
            }
        }.value
    }

    private static func codecOptions(for encoding: AudioCompressionEncoding) -> [String] {
        switch encoding.format {
        case .aac:
            // FFmpeg's fast AAC coder keeps low bitrate stereo near its target.
            return ["-c:a", "aac", "-aac_coder", "fast"]
        case .opus:
            if encoding.channels == .stereo, encoding.bitsPerSecond <= 16_000 {
                // libopus switches to a mono stream at these rates. FFmpeg's Opus
                // encoder keeps stereo in the standard two-channel mapping.
                return ["-c:a", "opus", "-strict", "experimental"]
            }
            return ["-c:a", "libopus", "-vbr", "off"]
        case .mp3:
            return ["-c:a", "libmp3lame", "-joint_stereo", "0"]
        }
    }

    /// Ogg Opus playback support varies with macOS. Decode the actual encoded excerpt
    /// so the A/B player can use the same timing and playback path for all formats.
    static func decodeOpusPreview(from source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try convert(input: .file(source, duration: 0), to: destination, options: ["-c:a", "pcm_s16le"])
        }.value
    }

    static func writeExcerpt(from input: AudioCompressionInput, to destination: URL) async throws {
        let start = AudioExcerpt.start(forDuration: input.duration)
        try await Task.detached(priority: .userInitiated) {
            switch input {
            case .file(let source, _):
                _ = try AudioExcerpt.write(from: source, start: start, to: destination)
            case .mix:
                try convert(input: input, to: destination, options: ["-c:a", "pcm_f32le"],
                            start: start, length: min(AudioExcerpt.length, input.duration - start))
            }
        }.value
    }

    private static func convert(
        input: AudioCompressionInput,
        to destination: URL,
        options: [String],
        progress: (@Sendable (TimeInterval) -> Void)? = nil,
        start: TimeInterval = 0,
        length: TimeInterval? = nil
    ) throws {
        guard let ffmpegURL else { throw Failure.missingFFmpeg }
        let process = Process()
        let output = Pipe()
        process.executableURL = ffmpegURL
        // Packet timestamps remain available when Ogg omits the muxer's out_time.
        let reporting = progress == nil ? [] : ["-stats_enc_post", "pipe:1", "-stats_enc_post_fmt", "\(progressKey){t}"]
        let inputOptions = try arguments(for: input, start: start, length: length)
        process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-xerror"]
            + inputOptions + ["-map_metadata", "-1"] + options + reporting + [destination.path]
        // Drain both streams together so neither can block the encoder.
        process.standardError = output
        process.standardOutput = output
        try process.run()
        let diagnostic = readProgress(from: output.fileHandleForReading, progress: progress)
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.failed(diagnostic ?? "")
        }
    }

    private static func arguments(
        for input: AudioCompressionInput,
        start: TimeInterval,
        length: TimeInterval?
    ) throws -> [String] {
        let localInput = ["-protocol_whitelist", "file,pipe"]
        switch input {
        case .file(let url, _):
            return localInput + ["-i", url.path, "-map", "0:a:0"]
        case .mix(let tracks, _):
            let audible = tracks.filter { $0.offset + $0.duration > start && $0.offset < start + (length ?? .infinity) }
            guard !audible.isEmpty else { throw AudioTranscodingError.couldNotConvert }
            var inputs: [String] = []
            var filters: [String] = []
            var labels = ""
            for (index, track) in audible.enumerated() {
                let seek = max(0, start - track.offset)
                inputs += localInput + ["-ss", String(seek), "-i", track.url.path]
                let delay = Int((max(0, track.offset - start) * 48_000).rounded())
                filters.append("[\(index):a:0]asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo,adelay=\(delay)S:all=1[a\(index)]")
                labels += "[a\(index)]"
            }
            // Fixed gain matches the recorded mix and avoids clipping or level jumps.
            filters.append("\(labels)amix=inputs=\(audible.count):duration=longest:normalize=0,volume=\(1.0 / Double(tracks.count))[mix]")
            inputs += ["-filter_complex", filters.joined(separator: ";"), "-map", "[mix]"]
            if let length { inputs += ["-t", String(length)] }
            return inputs
        }
    }

    private static func readProgress(
        from output: FileHandle,
        progress: (@Sendable (TimeInterval) -> Void)?
    ) -> String? {
        var buffer = Data()
        var diagnostic: String?
        var nextUpdate = ContinuousClock.now
        var lastTime: TimeInterval?
        while true {
            let chunk = output.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if line.hasPrefix(progressKey) {
                    guard let seconds = Double(line.dropFirst(progressKey.count)),
                          seconds.isFinite, seconds >= 0 else { continue }
                    lastTime = seconds
                    let now = ContinuousClock.now
                    if now >= nextUpdate {
                        progress?(seconds)
                        nextUpdate = now + .milliseconds(250)
                    }
                } else if diagnostic == nil, !line.isEmpty {
                    diagnostic = line
                }
            }
        }
        if let lastTime { progress?(lastTime) }
        return diagnostic
    }
}
