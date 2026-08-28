import Foundation
import XCTest
@testable import Bardo

final class CaptureIntegrityTests: XCTestCase {
    func testFinalizedDurationAcceptsCodecScaleDifferences() throws {
        XCTAssertNoThrow(
            try CaptureDurationIntegrity.validate(
                expected: 120,
                finalized: 119.6
            )
        )
    }

    func testFinalizedDurationRejectsMaterialCaptureLoss() {
        XCTAssertThrowsError(
            try CaptureDurationIntegrity.validate(
                expected: 120,
                finalized: 90
            )
        ) { error in
            XCTAssertEqual(
                error as? CaptureDurationIntegrityError,
                .truncated(expected: 120, finalized: 90)
            )
        }
    }

    func testPauseTimelineRemovesSourceClockGap() {
        var timeline = CapturePauseTimeline()

        XCTAssertEqual(
            timeline.decision(for: 100),
            CapturePauseDecision(shouldAppend: true, timestampOffset: 0)
        )

        timeline.pause()
        XCTAssertEqual(
            timeline.decision(for: 110),
            CapturePauseDecision(shouldAppend: false, timestampOffset: 0)
        )
        XCTAssertEqual(
            timeline.decision(for: 114),
            CapturePauseDecision(shouldAppend: false, timestampOffset: 0)
        )

        timeline.resume()
        let resumed = timeline.decision(for: 120)
        XCTAssertTrue(resumed.shouldAppend)
        XCTAssertEqual(resumed.timestampOffset, 10, accuracy: 0.000_001)

        let next = timeline.decision(for: 121)
        XCTAssertTrue(next.shouldAppend)
        XCTAssertEqual(next.timestampOffset, 10, accuracy: 0.000_001)
    }

    func testMultiplePauseResumeCyclesAccumulateOffsets() {
        var timeline = CapturePauseTimeline()
        _ = timeline.decision(for: 0)

        timeline.pause()
        _ = timeline.decision(for: 10)
        timeline.resume()
        XCTAssertEqual(timeline.decision(for: 15).timestampOffset, 5, accuracy: 0.000_001)

        timeline.pause()
        _ = timeline.decision(for: 20)
        timeline.resume()
        XCTAssertEqual(timeline.decision(for: 24).timestampOffset, 9, accuracy: 0.000_001)
    }
}
