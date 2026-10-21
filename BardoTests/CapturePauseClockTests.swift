import CoreMedia
import XCTest
@testable import Bardo

final class CapturePauseClockTests: XCTestCase {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48_000)
    }

    func testAudioDuringAPauseIsDroppedAndLaterAudioMovesBack() throws {
        let clock = CapturePauseClock()
        clock.pause(at: time(1))
        XCTAssertTrue(clock.isPaused)
        clock.resume(at: time(2))
        XCTAssertFalse(clock.isPaused)

        XCTAssertEqual(clock.offset(for: time(0.5)), .zero, "Audio before the pause is untouched")
        XCTAssertNil(clock.offset(for: time(1.5)), "Audio heard while paused is not recorded")
        XCTAssertEqual(try XCTUnwrap(clock.offset(for: time(2.5))).seconds, 1, accuracy: 1e-6)
    }

    func testABufferDeliveredLateKeepsItsPlaceWhilePaused() {
        let clock = CapturePauseClock()
        clock.pause(at: time(3))

        XCTAssertEqual(clock.offset(for: time(2.9)), .zero, "Captured before the pause, delivered after it")
        XCTAssertNil(clock.offset(for: time(3.1)))
    }

    func testPausesAddUpAndResetStartsOver() throws {
        let clock = CapturePauseClock()
        clock.pause(at: time(1)); clock.resume(at: time(2))
        clock.pause(at: time(4)); clock.resume(at: time(4.5))

        XCTAssertEqual(try XCTUnwrap(clock.offset(for: time(5))).seconds, 1.5, accuracy: 1e-6)
        clock.reset()
        XCTAssertEqual(clock.offset(for: time(5)), .zero)
    }

    func testRetimedBuffersContinueWhereTheRecordingPaused() throws {
        // Synthetic buffers start a little past 20 s on their clock.
        let base = 1_000_000.0 / 48_000
        let clock = CapturePauseClock()
        clock.pause(at: time(base + 1))
        clock.resume(at: time(base + 2))

        let after = try XCTUnwrap(SyntheticAudio.buffers(seconds: 0.02, channels: 1, startFrame: 120_000).first)
        let retimed = try XCTUnwrap(clock.retime(after))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(retimed).seconds, base + 1.5, accuracy: 1e-6)
        XCTAssertEqual(CMSampleBufferGetNumSamples(retimed), CMSampleBufferGetNumSamples(after))

        let during = try XCTUnwrap(SyntheticAudio.buffers(seconds: 0.02, channels: 1, startFrame: 72_000).first)
        XCTAssertNil(clock.retime(during))
    }
}
