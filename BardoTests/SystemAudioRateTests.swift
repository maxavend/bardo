import AVFoundation
import CoreAudio
import CoreMedia
import XCTest
@testable import Bardo

/// A Bluetooth speaker used as the Mac's output drops to 8 kHz once its microphone
/// opens. A 54-minute call recorded that way played six times too fast because its
/// 8 kHz audio was labeled 48 kHz; these tests keep the system track at the real rate.
final class SystemAudioRateTests: XCTestCase {
    private static let tapFormat = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    private var baseURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSystemAudioRate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseURL { try? FileManager.default.removeItem(at: baseURL) }
        baseURL = nil
    }

    func testHandsFreeRateBecomesRealTimeAudioAt48kHz() throws {
        let converter = try XCTUnwrap(SystemAudioFrameConverter(tapFormat: Self.tapFormat, sampleRate: 8_000))
        let cycles = TapCycles(rate: 8_000)

        let buffers = (0..<100).compactMap { _ in cycles.next(frames: 80, into: converter) }
        let duration = buffers.map { CMTimeGetSeconds(CMSampleBufferGetDuration($0)) }.reduce(0, +)

        XCTAssertEqual(duration, 1, accuracy: 0.02, "One second of 8 kHz audio must last one second")
        for buffer in buffers {
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(buffer))
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, 48_000)
        }
    }

    func testAudioAlreadyAt48kHzPassesThroughUnchanged() throws {
        let converter = try XCTUnwrap(SystemAudioFrameConverter(tapFormat: Self.tapFormat, sampleRate: 48_000))
        let cycles = TapCycles(rate: 48_000)

        let buffer = try XCTUnwrap(cycles.next(frames: 512, into: converter))

        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 512)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetDuration(buffer)), 512.0 / 48_000, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)), cycles.firstHostSeconds, accuracy: 1e-6)
    }

    func testRateDropMidRecordingKeepsTheTimeline() throws {
        let converter = try XCTUnwrap(SystemAudioFrameConverter(tapFormat: Self.tapFormat, sampleRate: 48_000))
        let cycles = TapCycles(rate: 48_000)
        var buffers = (0..<50).compactMap { _ in cycles.next(frames: 480, into: converter) }

        // The speaker switches to hands-free and Core Audio reports the new rate.
        cycles.rate = 8_000
        converter.setSampleRate(8_000)
        buffers += (0..<50).compactMap { _ in cycles.next(frames: 80, into: converter) }

        let duration = buffers.map { CMTimeGetSeconds(CMSampleBufferGetDuration($0)) }.reduce(0, +)
        XCTAssertEqual(duration, 1, accuracy: 0.02)
    }

    func testRateChangeIsCaughtFromTimestampsBeforeItsNotification() throws {
        let converter = try XCTUnwrap(SystemAudioFrameConverter(tapFormat: Self.tapFormat, sampleRate: 48_000))
        let cycles = TapCycles(rate: 8_000)

        let buffers = (0..<100).compactMap { _ in cycles.next(frames: 80, into: converter) }

        XCTAssertEqual(converter.sampleRate, 8_000)
        let duration = buffers.map { CMTimeGetSeconds(CMSampleBufferGetDuration($0)) }.reduce(0, +)
        // Only the cycles before the change was confirmed can be mislabeled.
        XCTAssertEqual(duration, 1, accuracy: 0.05)
    }

    func testEstimatorNeedsConsistentCyclesAndIgnoresDiscontinuities() {
        var estimator = SampleRateEstimator()
        let tick = hostTicks(seconds: 0.01)

        XCTAssertNil(estimator.observe(sampleTime: 0, hostTime: 1_000_000, currentRate: 48_000))
        XCTAssertNil(estimator.observe(sampleTime: 480, hostTime: 1_000_000 + tick, currentRate: 48_000), "Matches the known rate")
        XCTAssertNil(estimator.observe(sampleTime: 560, hostTime: 1_000_000 + 2 * tick, currentRate: 48_000), "One cycle is not enough")
        XCTAssertEqual(estimator.observe(sampleTime: 640, hostTime: 1_000_000 + 3 * tick, currentRate: 48_000), 8_000)

        var restarted = SampleRateEstimator()
        XCTAssertNil(restarted.observe(sampleTime: 10_000, hostTime: 1_000_000, currentRate: 48_000))
        XCTAssertNil(restarted.observe(sampleTime: 0, hostTime: 1_000_000 + tick, currentRate: 48_000), "A reset sample clock is ignored")
        XCTAssertNil(restarted.observe(sampleTime: 80, hostTime: 1_000_000 + 2 * tick, currentRate: 48_000))
        XCTAssertNil(restarted.observe(sampleTime: 1_000, hostTime: 1_000_000 + 3 * tick, currentRate: 48_000), "Not a standard rate")
    }

    func testOnlyTheTapsStreamIsRecordedWhenTheOutputHasInputs() throws {
        let converter = try XCTUnwrap(SystemAudioFrameConverter(tapFormat: Self.tapFormat, sampleRate: 48_000))
        let frames = 256
        var microphone = [Float](repeating: 0.9, count: frames)
        var tap = [Float](repeating: 0, count: frames * 2)
        for index in tap.indices { tap[index] = Float(index % 7) / 10 }

        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        let buffer = try microphone.withUnsafeMutableBytes { microphoneBytes in
            try tap.withUnsafeMutableBytes { tapBytes in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(microphoneBytes.count), mData: microphoneBytes.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count), mData: tapBytes.baseAddress)
                return try XCTUnwrap(converter.sampleBuffer(from: list.unsafePointer, at: TapCycles.timestamp(sampleTime: 0, hostTime: 1_000)))
            }
        }

        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), frames)
        var copied = [Float](repeating: -1, count: frames * 2)
        try copied.withUnsafeMutableBytes { bytes in
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
            XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!), noErr)
        }
        XCTAssertEqual(copied, tap)
    }

    func testSystemTrackWrittenFromHandsFreeAudioKeepsItsDuration() async throws {
        let converter = try XCTUnwrap(SystemAudioFrameConverter(tapFormat: Self.tapFormat, sampleRate: 8_000))
        let cycles = TapCycles(rate: 8_000)
        let url = baseURL.appendingPathComponent("system.m4a")
        let writer = CMSampleBufferAudioWriter(outputURL: url, channelCount: 2)

        for _ in 0..<200 {
            guard let buffer = cycles.next(frames: 80, into: converter) else { continue }
            XCTAssertEqual(writer.append(buffer), .accepted)
        }
        _ = try await writer.finish(sourceName: "System audio")

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 2, accuracy: 0.1)
    }

    private func hostTicks(seconds: Double) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
}

/// Simulates the aggregate device's IO cycles: stereo Float32 sine audio with sample and
/// host timestamps advancing at `rate`.
private final class TapCycles {
    var rate: Double
    private var sampleTime: Double = 0
    private var hostSeconds: Double = 100
    private var phase: Double = 0
    let firstHostSeconds: Double = 100

    init(rate: Double) {
        self.rate = rate
    }

    func next(frames: Int, into converter: SystemAudioFrameConverter) -> CMSampleBuffer? {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(sin(phase) * 0.2)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
            phase += 2 * .pi * 440 / rate
        }
        let hostTime = CMClockConvertHostTimeToSystemUnits(CMTime(seconds: hostSeconds, preferredTimescale: 1_000_000_000))
        let time = Self.timestamp(sampleTime: sampleTime, hostTime: hostTime)
        sampleTime += Double(frames)
        hostSeconds += Double(frames) / rate

        return samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            )
            return converter.sampleBuffer(from: &list, at: time)
        }
    }

    static func timestamp(sampleTime: Double, hostTime: UInt64) -> AudioTimeStamp {
        var time = AudioTimeStamp()
        time.mSampleTime = sampleTime
        time.mHostTime = hostTime
        time.mFlags = [.sampleTimeValid, .hostTimeValid]
        return time
    }
}
