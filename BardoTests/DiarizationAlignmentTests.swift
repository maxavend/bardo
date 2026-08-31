import Foundation
import XCTest
@testable import Bardo

final class DiarizationAlignmentTests: XCTestCase {
    func testAlignerOrdersSpeakersByFirstAppearanceAndPreservesTranscriptText() throws {
        let firstID = UUID()
        let secondID = UUID()
        let transcript = Transcript(
            recordingID: UUID(),
            languageCode: "en",
            segments: [
                TranscriptSegment(
                    id: firstID,
                    startTime: 0,
                    endTime: 1,
                    text: "Hello there.",
                    words: [
                        TranscriptWord(startTime: 0.1, endTime: 0.4, text: "Hello"),
                        TranscriptWord(startTime: 0.5, endTime: 0.9, text: " there.")
                    ]
                ),
                TranscriptSegment(
                    id: secondID,
                    startTime: 1,
                    endTime: 2,
                    text: "General Kenobi.",
                    words: [
                        TranscriptWord(startTime: 1.1, endTime: 1.5, text: "General"),
                        TranscriptWord(startTime: 1.5, endTime: 1.9, text: " Kenobi.")
                    ]
                )
            ],
            metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: "fixture")
        )
        let originalText = transcript.text

        let aligned = try TranscriptSpeakerAligner.applying(
            intervals: [
                DiarizationInterval(speakerIndex: 8, startTime: 0, endTime: 0.95),
                DiarizationInterval(speakerIndex: 2, startTime: 1.0, endTime: 2.0)
            ],
            to: transcript,
            metadata: DiarizationMetadata(
                engine: "SpeakerKit",
                engineVersion: "1.0.0",
                modelID: "pyannote-v3",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        XCTAssertEqual(aligned.text, originalText)
        XCTAssertEqual(aligned.segments.map(\.id), [firstID, secondID])
        XCTAssertEqual(aligned.speakers.count, 2)
        XCTAssertEqual(aligned.segments[0].speakerID, aligned.speakers[0].id)
        XCTAssertEqual(aligned.segments[1].speakerID, aligned.speakers[1].id)
        XCTAssertEqual(aligned.diarizationMetadata?.engine, "SpeakerKit")
    }

    func testWordOverlapVotesDetermineSpeakerWithoutChangingSegmentBounds() throws {
        let segmentID = UUID()
        let transcript = Transcript(
            recordingID: UUID(),
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    startTime: 0,
                    endTime: 3,
                    text: "One two three.",
                    words: [
                        TranscriptWord(startTime: 0.0, endTime: 0.4, text: "One"),
                        TranscriptWord(startTime: 0.5, endTime: 1.8, text: " two"),
                        TranscriptWord(startTime: 1.9, endTime: 2.8, text: " three.")
                    ]
                )
            ],
            metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: "fixture")
        )

        let aligned = try TranscriptSpeakerAligner.applying(
            intervals: [
                DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 0.45),
                DiarizationInterval(speakerIndex: 1, startTime: 0.45, endTime: 3)
            ],
            to: transcript,
            metadata: DiarizationMetadata(engine: "SpeakerKit", engineVersion: "1", modelID: "fixture")
        )

        XCTAssertEqual(aligned.segments[0].id, segmentID)
        XCTAssertEqual(aligned.segments[0].startTime, 0)
        XCTAssertEqual(aligned.segments[0].endTime, 3)
        XCTAssertEqual(aligned.segments[0].text, "One two three.")
        XCTAssertEqual(aligned.segments[0].speakerID, aligned.speakers[1].id)
    }

    func testDetectedSpeakersWithoutTranscriptOverlapFailsAsAlignmentProblem() {
        let transcript = Transcript(
            recordingID: UUID(),
            segments: [
                TranscriptSegment(startTime: 10, endTime: 11, text: "Silence gap label")
            ],
            metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: "fixture")
        )

        XCTAssertThrowsError(
            try TranscriptSpeakerAligner.applying(
                intervals: [DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 1)],
                to: transcript,
                metadata: DiarizationMetadata(engine: "SpeakerKit", engineVersion: "1", modelID: "fixture")
            )
        ) { error in
            XCTAssertEqual(error as? RecordingDiarizationError, .alignmentProducedNoAssignments)
        }
    }

    func testSingleSpeakerResultIsValidWhenItAligns() throws {
        let transcript = Transcript(
            recordingID: UUID(),
            segments: [TranscriptSegment(startTime: 0, endTime: 2, text: "Only one voice.")],
            metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: "fixture")
        )

        let aligned = try TranscriptSpeakerAligner.applying(
            intervals: [DiarizationInterval(speakerIndex: 4, startTime: 0, endTime: 2)],
            to: transcript,
            metadata: DiarizationMetadata(engine: "SpeakerKit", engineVersion: "1", modelID: "fixture")
        )

        XCTAssertEqual(aligned.speakers.count, 1)
        XCTAssertEqual(aligned.segments.first?.speakerID, aligned.speakers.first?.id)
    }

    func testNoValidSpeakerActivityFailsWithoutMutatingTranscript() {
        let transcript = Transcript(
            recordingID: UUID(),
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Hello")],
            metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: "fixture")
        )

        XCTAssertThrowsError(
            try TranscriptSpeakerAligner.applying(
                intervals: [
                    DiarizationInterval(speakerIndex: -1, startTime: 0, endTime: 1),
                    DiarizationInterval(speakerIndex: 0, startTime: 2, endTime: 2)
                ],
                to: transcript,
                metadata: DiarizationMetadata(engine: "SpeakerKit", engineVersion: "1", modelID: "fixture")
            )
        ) { error in
            XCTAssertEqual(error as? RecordingDiarizationError, .noSpeakerActivity)
        }
    }
}
