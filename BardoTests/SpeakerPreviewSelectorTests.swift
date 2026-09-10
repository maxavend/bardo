import Foundation
import XCTest
@testable import Bardo

final class SpeakerPreviewSelectorTests: XCTestCase {
    func testSelectsLongestContinuousIntervalForEachSpeaker() throws {
        let firstSpeaker = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let secondSpeaker = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        let transcript = makeTranscript(
            speakers: [Speaker(id: firstSpeaker), Speaker(id: secondSpeaker)],
            segments: [
                TranscriptSegment(startTime: 10, endTime: 11, speakerID: firstSpeaker, text: "short"),
                TranscriptSegment(startTime: 0, endTime: 2, speakerID: firstSpeaker, text: "long"),
                TranscriptSegment(startTime: 2, endTime: 6, speakerID: firstSpeaker, text: "long"),
                TranscriptSegment(startTime: 8, endTime: 9, speakerID: firstSpeaker, text: "gap"),
                TranscriptSegment(startTime: 20, endTime: 23, speakerID: secondSpeaker, text: "second")
            ]
        )

        XCTAssertEqual(
            SpeakerPreviewSelector.previews(for: transcript),
            [
                SpeakerPreview(speakerID: firstSpeaker, startTime: 0, endTime: 6),
                SpeakerPreview(speakerID: secondSpeaker, startTime: 20, endTime: 23)
            ]
        )
    }

    func testCapsPreviewToTenSecondsWithoutLeavingKnownInterval() throws {
        let speakerID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
        let transcript = makeTranscript(
            speakers: [Speaker(id: speakerID)],
            segments: [
                TranscriptSegment(startTime: 4, endTime: 30, speakerID: speakerID, text: "long segment")
            ]
        )

        let preview = try XCTUnwrap(SpeakerPreviewSelector.previews(for: transcript).first)
        XCTAssertEqual(preview.startTime, 4)
        XCTAssertEqual(preview.endTime, 14)
        XCTAssertLessThanOrEqual(preview.endTime - preview.startTime, 10)
    }

    func testUsesCustomMaximumDuration() throws {
        let speakerID = UUID(uuidString: "00000000-0000-0000-0000-000000000704")!
        let transcript = makeTranscript(
            speakers: [Speaker(id: speakerID)],
            segments: [
                TranscriptSegment(startTime: 1, endTime: 8, speakerID: speakerID, text: "segment")
            ]
        )

        let preview = try XCTUnwrap(
            SpeakerPreviewSelector.previews(for: transcript, maxDuration: 3).first
        )
        XCTAssertEqual(preview, SpeakerPreview(speakerID: speakerID, startTime: 1, endTime: 4))
    }

    func testUsesWordEvidenceToTrimPreviewWithinSegmentBounds() throws {
        let speakerID = UUID(uuidString: "00000000-0000-0000-0000-000000000705")!
        let transcript = makeTranscript(
            speakers: [Speaker(id: speakerID)],
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 10,
                    speakerID: speakerID,
                    text: "word-timed segment",
                    words: [
                        TranscriptWord(startTime: 2, endTime: 3, text: "word"),
                        TranscriptWord(startTime: 4, endTime: 6, text: "evidence")
                    ]
                )
            ]
        )

        let preview = try XCTUnwrap(SpeakerPreviewSelector.previews(for: transcript).first)
        XCTAssertEqual(preview, SpeakerPreview(speakerID: speakerID, startTime: 2, endTime: 6))
    }

    private func makeTranscript(speakers: [Speaker], segments: [TranscriptSegment]) -> Transcript {
        Transcript(
            recordingID: UUID(),
            speakers: speakers,
            segments: segments,
            metadata: TranscriptMetadata(
                engine: "test",
                engineVersion: "1",
                modelID: "test"
            )
        )
    }
}
