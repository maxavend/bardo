import AVFoundation
import XCTest
@testable import Bardo

final class LiveRecorderTests: XCTestCase {
    func testMeterAddsOneBarPerTwentiethOfASecondOfAudio() {
        let meter = LiveAudioMeter()

        for buffer in SyntheticAudio.buffers(seconds: 1, channels: 2) {
            meter.append(buffer)
        }

        let snapshot = meter.snapshot
        XCTAssertEqual(snapshot.levels.count, 20)
        XCTAssertEqual(snapshot.duration, 1, accuracy: 0.001)
        XCTAssertGreaterThan(snapshot.heardAt, 0)
        // A -14 dBFS tone (RMS about -17 dB) sits high on a 50 dB scale.
        XCTAssertEqual(Double(snapshot.levels[10]), 0.66, accuracy: 0.03)
    }

    func testSilenceIsTheBottomOfTheScaleAndFullScaleTheTop() {
        XCTAssertEqual(LiveAudioMeter.level(meanSquare: 0), 0)
        XCTAssertEqual(LiveAudioMeter.level(meanSquare: 1e-7), 0, "Below -50 dB")
        XCTAssertEqual(LiveAudioMeter.level(meanSquare: 1), 1)
        XCTAssertEqual(LiveAudioMeter.level(meanSquare: pow(10, -2.5)), 0.5, accuracy: 0.001, "-25 dB is halfway")
    }

    func testMeterKeepsOnlyRecentBarsAndStartsOverOnReset() {
        let meter = LiveAudioMeter()
        let samples = [Float](repeating: 0.1, count: 48_000)
        samples.withUnsafeBufferPointer { pointer in
            for _ in 0..<25 {
                meter.append(pointer, frames: 48_000, sampleRate: 48_000)
            }
        }
        XCTAssertEqual(meter.snapshot.levels.count, LiveAudioMeter.capacity)
        XCTAssertEqual(meter.snapshot.duration, 25, accuracy: 0.001)

        meter.reset()
        XCTAssertEqual(meter.snapshot, LiveAudioMeter.Snapshot(levels: [], heardAt: 0, duration: 0))
    }

    func testHandsFreeMicrophoneAudioShowsAtItsOwnRate() {
        let meter = LiveAudioMeter()
        let samples = [Float](repeating: 0.1, count: 160)
        samples.withUnsafeBufferPointer { pointer in
            for _ in 0..<100 {
                meter.append(pointer, frames: 160, sampleRate: 16_000)
            }
        }
        XCTAssertEqual(meter.snapshot.levels.count, 20)
        XCTAssertEqual(meter.snapshot.duration, 1, accuracy: 0.001)
    }

    @MainActor
    func testWaveGlidesEvenlyWhileAudioArrivesInUnevenBuffers() {
        let meter = LiveAudioMeter()
        let track = LiveRecorderTrack.system(meter)
        let motion = LiveWaveMotion()
        let samples = [Float](repeating: 0.1, count: 4_096)
        let start = Date()
        var nextBuffer = 0.0
        var buffers = 0
        var times: [TimeInterval] = []
        // Three seconds at 120 Hz, with 4,096-frame buffers arriving up to 30 ms late.
        for frame in 0..<360 {
            let now = Double(frame) / 120
            while nextBuffer <= now {
                samples.withUnsafeBufferPointer { meter.append($0, frames: 4_096, sampleRate: 48_000, at: 1_000 + nextBuffer) }
                buffers += 1
                nextBuffer = Double(buffers) * 4_096 / 48_000 + Double(buffers % 3) * 0.015
            }
            let time = motion.frame(for: [track], at: start.addingTimeInterval(now), isMoving: true, now: 1_000 + now)[0].time
            times.append(time)
        }

        // Once it has caught up, every frame moves the audio forward by about one
        // frame's worth, never jumping or stopping.
        for (previous, time) in zip(times[60...], times[61...]) {
            XCTAssertEqual(time - previous, 1.0 / 120, accuracy: 0.004)
        }
        XCTAssertEqual(times.last!, meter.snapshot.duration, accuracy: 0.2)
    }

    @MainActor
    func testMicrophoneWriterFeedsTheMeterOnlyWhileRecording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BardoMeter-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let meter = LiveAudioMeter()
        let writer = try MicrophoneFileWriter(url: url, settings: MicrophoneCaptureBackend.recordingSettings, meter: meter)

        for buffer in SyntheticAudio.buffers(seconds: 0.5, channels: 1) { writer.append(buffer) }
        writer.isPaused = true
        for buffer in SyntheticAudio.buffers(seconds: 0.5, channels: 1, startFrame: 24_000) { writer.append(buffer) }
        writer.close()

        XCTAssertEqual(meter.snapshot.duration, 0.5, accuracy: 0.03)
        XCTAssertEqual(meter.snapshot.levels.count, 10)
    }

    func testClockShowsHundredthsWithTheLocaleSeparator() {
        let spanish = Locale(identifier: "es_CL")
        XCTAssertEqual(LiveRecorderClock.format(5.987, locale: spanish), "00:05,98")
        XCTAssertEqual(LiveRecorderClock.format(342.17, locale: Locale(identifier: "en_US")), "05:42.17")
        XCTAssertEqual(LiveRecorderClock.format(3_942.5, locale: spanish), "1:05:42,50")
        XCTAssertEqual(LiveRecorderClock.format(-1, locale: spanish), "00:00,00")
    }
}
