import Foundation
import XCTest
@testable import Bardo

final class SpeakerPreviewTests: XCTestCase {
    func testPreviewChoosesLongestContinuousRunForSpeaker() {
        let speaker = UUID()
        let other = UUID()
        let segments = [
            segment(start: 0, end: 2, speakerID: speaker),
            segment(start: 2.2, end: 4.5, speakerID: speaker),
            segment(start: 5, end: 8, speakerID: other),
            segment(start: 10, end: 15.5, speakerID: speaker)
        ]

        guard let clip = SpeakerPreviewClipSelector.clip(
            for: speaker,
            in: segments,
            maximumDuration: 10
        ) else {
            return XCTFail("Expected a preview clip for the speaker")
        }

        XCTAssertEqual(clip.startTime, 10, accuracy: 0.001)
        XCTAssertEqual(clip.endTime, 15.5, accuracy: 0.001)
    }

    func testPreviewNeverExceedsMaximumDuration() {
        let speaker = UUID()
        let segments = [
            segment(start: 20, end: 36, speakerID: speaker)
        ]

        guard let clip = SpeakerPreviewClipSelector.clip(
            for: speaker,
            in: segments,
            maximumDuration: 10
        ) else {
            return XCTFail("Expected a preview clip for the speaker")
        }

        XCTAssertEqual(clip.startTime, 20, accuracy: 0.001)
        XCTAssertEqual(clip.endTime, 30, accuracy: 0.001)
        XCTAssertEqual(clip.duration, 10, accuracy: 0.001)
    }

    func testPreviewDoesNotBridgeAcrossAnotherSpeaker() {
        let speaker = UUID()
        let other = UUID()
        let segments = [
            segment(start: 0, end: 4, speakerID: speaker),
            segment(start: 4.1, end: 4.8, speakerID: other),
            segment(start: 4.9, end: 9, speakerID: speaker)
        ]

        guard let clip = SpeakerPreviewClipSelector.clip(
            for: speaker,
            in: segments,
            maximumDuration: 10
        ) else {
            return XCTFail("Expected a preview clip for the speaker")
        }

        XCTAssertEqual(clip.startTime, 4.9, accuracy: 0.001)
        XCTAssertEqual(clip.endTime, 9, accuracy: 0.001)
    }

    func testPreviewReturnsNilWhenSpeakerHasNoAssignedSegments() {
        let speaker = UUID()
        let other = UUID()
        let segments = [
            segment(start: 0, end: 3, speakerID: other)
        ]

        XCTAssertNil(
            SpeakerPreviewClipSelector.clip(
                for: speaker,
                in: segments,
                maximumDuration: 10
            )
        )
    }

    private func segment(
        start: TimeInterval,
        end: TimeInterval,
        speakerID: Speaker.ID
    ) -> TranscriptSegment {
        TranscriptSegment(
            startTime: start,
            endTime: end,
            speakerID: speakerID,
            text: "Sample"
        )
    }
}
