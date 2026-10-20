import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import OSLog

/// Turns the system tap's IO cycles into 48 kHz sample buffers.
///
/// The tap reaches Bardo through an aggregate device, which runs at its output device's
/// rate. That rate can change mid-recording: a Bluetooth speaker drops to 8 or 16 kHz
/// once its microphone opens. Every cycle is read at the rate the device actually runs
/// at and converted to one fixed format, so the writer never sees a format change and
/// the track never plays sped up or slowed down.
final class SystemAudioFrameConverter: @unchecked Sendable {
    static let outputSampleRate: Double = 48_000

    let outputFormat: AVAudioFormat
    private let tapFormat: AudioStreamBasicDescription
    private let lock = NSLock()
    private static let logger = Logger(subsystem: "com.maxavend.bardo", category: "capture.system-audio")

    // Guarded by `lock`.
    private var sourceRate: Double
    private var sourceFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var estimator = SampleRateEstimator()

    /// - Parameters:
    ///   - tapFormat: The tap's channel layout and sample format.
    ///   - sampleRate: The rate the aggregate device runs at right now.
    init?(tapFormat: AudioStreamBasicDescription, sampleRate: Double) {
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mBytesPerFrame > 0,
              tapFormat.mChannelsPerFrame > 0,
              sampleRate > 0
        else { return nil }
        var output = tapFormat
        output.mSampleRate = Self.outputSampleRate
        var source = tapFormat
        source.mSampleRate = sampleRate
        guard let outputFormat = AVAudioFormat(streamDescription: &output),
              let sourceFormat = AVAudioFormat(streamDescription: &source)
        else { return nil }
        self.tapFormat = tapFormat
        self.outputFormat = outputFormat
        self.sourceFormat = sourceFormat
        self.sourceRate = sampleRate
    }

    var sampleRate: Double {
        lock.bardoWithLock { sourceRate }
    }

    /// Follows a change of the device's rate, such as a nominal-rate notification.
    func setSampleRate(_ rate: Double) {
        lock.bardoWithLock { setSampleRateLocked(rate) }
    }

    /// How many buffers of the cycle carry the tap: one when interleaved, one per channel
    /// otherwise. They are the last ones; an output device with its own inputs adds its
    /// streams first.
    var tapBufferCount: Int {
        tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(tapFormat.mChannelsPerFrame) : 1
    }

    /// Converts one IO cycle, stamped with the host time of its first frame.
    func sampleBuffer(from input: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) -> CMSampleBuffer? {
        guard time.mFlags.contains(.hostTimeValid) else { return nil }
        return lock.bardoWithLock {
            if time.mFlags.contains(.sampleTimeValid),
               let observed = estimator.observe(sampleTime: time.mSampleTime, hostTime: time.mHostTime, currentRate: sourceRate) {
                Self.logger.notice("System audio runs at \(observed, privacy: .public) Hz, not \(self.sourceRate, privacy: .public) Hz")
                setSampleRateLocked(observed)
            }
            let presentationTime = CMClockMakeHostTimeFromSystemUnits(time.mHostTime)
            // Both paths copy the audio into the sample buffer before the cycle returns.
            return withTapBuffer(from: input) { source in
                convertLocked(source).flatMap { Self.makeSampleBuffer($0, presentationTime: presentationTime) }
            }
        }
    }

    /// Whether any sample in the tap's part of the cycle is not digital silence.
    func containsSound(_ input: UnsafePointer<AudioBufferList>) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, tapFormat.mBitsPerChannel == 32 else { return true }
        for buffer in buffers.suffix(tapBufferCount) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            guard count > 0 else { continue }
            var peak: Float = 0
            vDSP_maxmgv(data, 1, &peak, count)
            if peak > 0 { return true }
        }
        return false
    }

    private func setSampleRateLocked(_ rate: Double) {
        guard rate > 0, rate != sourceRate else { return }
        var source = tapFormat
        source.mSampleRate = rate
        guard let format = AVAudioFormat(streamDescription: &source) else { return }
        sourceRate = rate
        sourceFormat = format
        converter = nil
        estimator = SampleRateEstimator()
    }

    /// Lends the tap's buffers of the cycle, read at the device's current rate, without
    /// copying. The view points at Core Audio's memory, so it never outlives `body`.
    private func withTapBuffer<T>(from input: UnsafePointer<AudioBufferList>, _ body: (AVAudioPCMBuffer) -> T?) -> T? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let count = tapBufferCount
        guard buffers.count >= count else { return nil }
        let first = buffers.count - count
        let expectedChannels = count == 1 ? tapFormat.mChannelsPerFrame : 1
        guard buffers[first].mNumberChannels == expectedChannels else { return nil }

        let list = AudioBufferList.allocate(maximumBuffers: count)
        defer { free(list.unsafeMutablePointer) }
        for index in 0..<count {
            list[index] = buffers[first + index]
        }
        guard let view = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: list.unsafePointer),
              view.frameLength > 0
        else { return nil }
        return body(view)
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if sourceRate == Self.outputSampleRate { return buffer }

        if converter == nil {
            converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let converter else { return nil }
        let ratio = Self.outputSampleRate / sourceRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = pending else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            pending = nil
            inputStatus.pointee = .haveData
            return next
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    static func makeSampleBuffer(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        let format = buffer.format
        guard buffer.frameLength > 0, format.sampleRate > 0 else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr else { return nil }
        CMSampleBufferSetDataReady(sampleBuffer)
        return sampleBuffer
    }
}

/// Measures the rate a device really runs at from its IO timestamps, so a rate change
/// is caught on the cycle it happens instead of when its notification arrives.
struct SampleRateEstimator: Sendable {
    static let standardRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    /// How far a measurement may stray from a standard rate and still count as it.
    static let tolerance = 0.03
    /// Consecutive cycles that must agree before the rate is trusted, so one cycle
    /// across a reconfiguration or a timestamp discontinuity is never enough.
    static let requiredAgreement = 2

    private var previous: (sampleTime: Double, hostTime: UInt64)?
    private var candidate: Double?
    private var agreement = 0

    /// Returns a new rate once the timestamps consistently show one other than `currentRate`.
    mutating func observe(sampleTime: Double, hostTime: UInt64, currentRate: Double) -> Double? {
        defer { previous = (sampleTime, hostTime) }
        guard let previous, hostTime > previous.hostTime, sampleTime > previous.sampleTime else {
            reset()
            return nil
        }
        let seconds = Self.seconds(fromHostTicks: hostTime - previous.hostTime)
        guard seconds > 0, let measured = Self.standardRate(near: (sampleTime - previous.sampleTime) / seconds) else {
            reset()
            return nil
        }
        guard measured != currentRate else {
            reset()
            return nil
        }
        if measured == candidate {
            agreement += 1
        } else {
            candidate = measured
            agreement = 1
        }
        guard agreement >= Self.requiredAgreement else { return nil }
        reset()
        return measured
    }

    static func standardRate(near value: Double) -> Double? {
        standardRates.first { abs(value - $0) / $0 <= tolerance }
    }

    static func seconds(fromHostTicks ticks: UInt64) -> Double {
        CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(ticks))
    }

    private mutating func reset() {
        candidate = nil
        agreement = 0
    }
}
