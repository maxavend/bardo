import Foundation

/// How loud a track is over time: one level every 20 ms, placed on the timeline.
struct TrackLoudness: Sendable {
    static let frameDuration: TimeInterval = 0.02
    /// Whisper's loader delivers 16 kHz mono samples.
    private static let sampleRate = 16_000.0
    private static let chunkDuration: TimeInterval = 60
    private static let silenceFloor: Float = 1e-6

    let offset: TimeInterval
    let levels: [Float]

    /// Reads the file a minute at a time, so even a long meeting never needs its whole
    /// audio in memory.
    static func measure(url: URL, duration: TimeInterval, offset: TimeInterval) throws -> TrackLoudness {
        let samplesPerFrame = Int(sampleRate * frameDuration)
        var levels: [Float] = []
        levels.reserveCapacity(Int(duration / frameDuration) + 1)

        var start: TimeInterval = 0
        while start < duration {
            let end = min(duration, start + chunkDuration)
            let samples = try BoundedWhisperAudioLoader.loadSamples(from: url, startTime: start, endTime: end)
            var index = 0
            while index + samplesPerFrame <= samples.count {
                var energy: Float = 0
                for sample in samples[index..<(index + samplesPerFrame)] {
                    energy += sample * sample
                }
                levels.append(log10((energy / Float(samplesPerFrame)).squareRoot() + silenceFloor))
                index += samplesPerFrame
            }
            start = end
        }
        return TrackLoudness(offset: offset, levels: levels)
    }

    /// The levels between two moments on the timeline, or nil where the track has none.
    func levels(from start: TimeInterval, count: Int) -> ArraySlice<Float>? {
        let first = Int(((start - offset) / Self.frameDuration).rounded())
        guard first >= 0, count > 0, first + count <= levels.count else { return nil }
        return levels[first..<(first + count)]
    }
}

/// Recognises a microphone turn that is the call heard again through the speakers: its
/// loudness rises and falls with the Mac's audio a few milliseconds later. It works in
/// any language and even when Whisper misheard the echo.
enum TrackEchoDetector {
    /// Speakers to microphone takes a few milliseconds; allow for slow audio paths.
    static let maximumDelay: TimeInterval = 0.3
    /// Measured on this Mac: an echo follows the call at 0.6–0.7, a different voice at
    /// about 0.
    static let threshold: Float = 0.5
    /// Shorter turns carry too little shape to compare.
    static let minimumDuration: TimeInterval = 0.5

    static func isEcho(_ segment: TranscriptSegment, microphone: TrackLoudness, system: TrackLoudness) -> Bool {
        let span = segment.endTime - segment.startTime
        guard span >= minimumDuration else { return false }
        let count = Int((span / TrackLoudness.frameDuration).rounded())
        guard let spoken = microphone.levels(from: segment.startTime, count: count) else { return false }

        let maximumLag = Int((maximumDelay / TrackLoudness.frameDuration).rounded())
        for lag in 0...maximumLag {
            let playedAt = segment.startTime - Double(lag) * TrackLoudness.frameDuration
            if let played = system.levels(from: playedAt, count: count),
               correlation(spoken, played) >= threshold {
                return true
            }
        }
        return false
    }

    /// Pearson correlation; a flat (silent) track correlates with nothing.
    static func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
        let count = Float(a.count)
        guard count > 1, a.count == b.count else { return 0 }
        let meanA = a.reduce(0, +) / count
        let meanB = b.reduce(0, +) / count
        var product: Float = 0
        var varianceA: Float = 0
        var varianceB: Float = 0
        for (x, y) in zip(a, b) {
            product += (x - meanA) * (y - meanB)
            varianceA += (x - meanA) * (x - meanA)
            varianceB += (y - meanB) * (y - meanB)
        }
        guard varianceA > 1e-3, varianceB > 1e-3 else { return 0 }
        return product / (varianceA * varianceB).squareRoot()
    }
}
