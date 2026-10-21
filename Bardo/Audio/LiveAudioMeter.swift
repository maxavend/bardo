import Accelerate
import CoreMedia
import Foundation

/// The recent loudness of one live track, for the recorder's waveform.
///
/// Capture queues append audio; the waveform reads a snapshot on every frame it draws.
/// Nothing here is published, so the levels never invalidate SwiftUI views: the waveform
/// redraws itself from a `TimelineView` while it is on screen.
final class LiveAudioMeter: @unchecked Sendable {
    /// One bar of the waveform covers this much audio.
    static let bucketDuration: TimeInterval = 0.05
    /// About twenty seconds of bars, more than the widest window shows.
    static let capacity = 400
    /// Levels map the range from this many decibels below full scale up to 0 dB.
    static let floorDecibels: Float = -50

    struct Snapshot: Equatable, Sendable {
        /// Bar heights from 0 to 1, oldest first.
        var levels: [Float]
        /// `ProcessInfo.systemUptime` when the newest bar was added.
        var lastBarTime: TimeInterval
        /// Seconds of audio the meter has heard.
        var duration: TimeInterval
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var levels: [Float] = []
    private var lastBarTime: TimeInterval = 0
    private var framesHeard: Double = 0
    private var bucketSquares: Float = 0
    private var bucketSamples = 0
    private var bucketFrames: Double = 0

    var snapshot: Snapshot {
        lock.bardoWithLock { Snapshot(levels: levels, lastBarTime: lastBarTime, duration: framesHeard) }
    }

    func reset() {
        lock.bardoWithLock {
            levels.removeAll(keepingCapacity: true)
            lastBarTime = 0
            framesHeard = 0
            bucketSquares = 0
            bucketSamples = 0
            bucketFrames = 0
        }
    }

    /// Adds one Float32 PCM sample buffer, the format both live tracks deliver.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mSampleRate > 0,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let length = CMBlockBufferGetDataLength(block)
        guard frames > 0, length >= MemoryLayout<Float>.size else { return }

        var pointer: UnsafeMutablePointer<CChar>?
        var contiguousLength = 0
        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguousLength, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
           contiguousLength == length, let pointer {
            pointer.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) { samples in
                append(UnsafeBufferPointer(start: samples, count: length / MemoryLayout<Float>.size), frames: frames, sampleRate: format.mSampleRate)
            }
        } else {
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            samples.withUnsafeBufferPointer { append($0, frames: frames, sampleRate: format.mSampleRate) }
        }
    }

    /// Adds `frames` frames of audio whose samples, of every channel, are `samples`.
    func append(_ samples: UnsafeBufferPointer<Float>, frames: Int, sampleRate: Double) {
        guard frames > 0, !samples.isEmpty, let base = samples.baseAddress else { return }
        var squares: Float = 0
        vDSP_svesq(base, 1, &squares, vDSP_Length(samples.count))
        let now = ProcessInfo.processInfo.systemUptime
        let framesPerBar = Self.bucketDuration * sampleRate

        lock.bardoWithLock {
            framesHeard += Double(frames) / sampleRate
            bucketSquares += squares
            bucketSamples += samples.count
            bucketFrames += Double(frames)
            guard bucketFrames >= framesPerBar else { return }
            // A buffer longer than a bar fills several bars with its level; frames left
            // over only carry the timing into the next bar.
            let level = Self.level(meanSquare: bucketSquares / Float(bucketSamples))
            while bucketFrames >= framesPerBar {
                levels.append(level)
                bucketFrames -= framesPerBar
            }
            bucketSquares = 0
            bucketSamples = 0
            lastBarTime = now
            if levels.count > Self.capacity {
                levels.removeFirst(levels.count - Self.capacity)
            }
        }
    }

    /// Maps loudness to a bar height on a decibel scale, so quiet speech still shows.
    static func level(meanSquare: Float) -> Float {
        guard meanSquare > 0 else { return 0 }
        let decibels = 10 * log10(meanSquare)
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}

#if DEBUG
extension LiveAudioMeter {
    /// The design review's recording: two tracks taking turns like a call, synthesized
    /// from a fixed seed so captures never record and always look the same.
    @MainActor
    final class DesignPreview {
        let microphone = LiveAudioMeter()
        let system = LiveAudioMeter()
        /// Like the real capture, a muted microphone records silence from then on.
        var isMicrophoneMuted = false
        private var generator = Conversation()
        private var task: Task<Void, Never>?

        /// - Parameter mutedTail: Seconds at the end of the prefilled history recorded
        ///   with the microphone muted, which then stays muted.
        init(mutedTail: TimeInterval = 0) {
            let bars = Int(14 / LiveAudioMeter.bucketDuration)
            let mutedBars = Int(mutedTail / LiveAudioMeter.bucketDuration)
            for bar in 0..<bars {
                isMicrophoneMuted = bar >= bars - mutedBars
                advance()
            }
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(LiveAudioMeter.bucketDuration))
                    self?.advance()
                }
            }
        }

        deinit {
            task?.cancel()
        }

        private func advance() {
            let (you, others) = generator.next()
            microphone.appendPreviewLevel(isMicrophoneMuted ? 0 : you)
            system.appendPreviewLevel(others)
        }
    }

    fileprivate func appendPreviewLevel(_ level: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.bardoWithLock {
            levels.append(level)
            if levels.count > Self.capacity { levels.removeFirst(levels.count - Self.capacity) }
            lastBarTime = now
            framesHeard += Self.bucketDuration
        }
    }
}

/// Turns of speech with syllables and pauses, alternating between the two tracks.
private struct Conversation {
    private var seed: UInt64 = 0x5EED_BA4D0
    private var speaker = 0
    private var remaining = 0
    private var phase: Float = 0

    mutating func next() -> (you: Float, others: Float) {
        if remaining <= 0 {
            speaker = speaker == 0 ? 1 : 0
            remaining = 30 + Int(random() * 50)
        }
        remaining -= 1
        phase += 0.9 + random() * 0.6
        // Syllables rise and fall; a short pause now and then between words.
        let syllable = 0.5 + 0.5 * sin(phase)
        let pause = random() < 0.12
        let speech = pause ? 0.18 + random() * 0.1 : 0.45 + 0.4 * syllable + random() * 0.15
        let room = 0.06 + random() * 0.05
        return speaker == 0 ? (min(1, speech), room) : (room, min(1, speech))
    }

    private mutating func random() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(seed >> 40) / Float(1 << 24)
    }
}
#endif
