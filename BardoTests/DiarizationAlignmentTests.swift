import Foundation
import XCTest
@testable import Bardo

final class DiarizationAlignmentTests: XCTestCase {
    private func metadata() -> DiarizationMetadata {
        DiarizationMetadata(engine: "SpeakerKit", engineVersion: "1.1.0", modelID: SpeakerDiarizationService.modelID)
    }

    func testCrossSpeakerWhisperSegmentIsRebuiltAtWordBoundaries() throws {
        let transcript = Transcript(recordingID: UUID(), segments: [TranscriptSegment(startTime: 0, endTime: 3, text: "Hello yes", words: [
            TranscriptWord(startTime: 0, endTime: 0.4, text: "Hello"),
            TranscriptWord(startTime: 0.5, endTime: 0.9, text: " yes")
        ])], metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: TranscriptionModelManager.modelID))
        let aligned = try TranscriptSpeakerAligner.applying(
            intervals: [DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 0.45), DiarizationInterval(speakerIndex: 1, startTime: 0.45, endTime: 1.2)],
            to: transcript, metadata: metadata()
        )
        XCTAssertEqual(aligned.segments.count, 2)
        XCTAssertEqual(aligned.segments.map(\.text), ["Hello", "yes"])
        XCTAssertEqual(aligned.segments.map { $0.words.count }, [1, 1])
        XCTAssertNotEqual(aligned.segments[0].speakerID, aligned.segments[1].speakerID)
    }

    func testAtoBtoAConversationKeepsThreeTurns() throws {
        let words = [
            TranscriptWord(startTime: 0, endTime: 0.2, text: "A"), TranscriptWord(startTime: 0.3, endTime: 0.5, text: "one"),
            TranscriptWord(startTime: 1, endTime: 1.2, text: "B"), TranscriptWord(startTime: 1.3, endTime: 1.5, text: "reply"),
            TranscriptWord(startTime: 2, endTime: 2.2, text: "A"), TranscriptWord(startTime: 2.3, endTime: 2.5, text: "again")
        ]
        let transcript = Transcript(recordingID: UUID(), segments: [TranscriptSegment(startTime: 0, endTime: 3, text: "A one B reply A again", words: words)], metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: TranscriptionModelManager.modelID))
        let aligned = try TranscriptSpeakerAligner.applying(
            intervals: [DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 0.8), DiarizationInterval(speakerIndex: 1, startTime: 0.8, endTime: 1.8), DiarizationInterval(speakerIndex: 0, startTime: 1.8, endTime: 3)],
            to: transcript, metadata: metadata()
        )
        XCTAssertEqual(aligned.segments.count, 3)
        XCTAssertEqual(aligned.segments.map(\.text), ["A one", "B reply", "A again"])
        XCTAssertEqual(aligned.segments[0].speakerID, aligned.segments[2].speakerID)
    }

    func testManualTextEditsAndOldSegmentBoundariesSurviveRediarization() throws {
        let segmentID = UUID()
        let transcript = Transcript(recordingID: UUID(), segments: [TranscriptSegment(id: segmentID, startTime: 0, endTime: 2, text: "Original", words: [TranscriptWord(startTime: 0, endTime: 1, text: "Original")], editedText: "Human correction")], metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: TranscriptionModelManager.modelID))
        let aligned = try TranscriptSpeakerAligner.applying(intervals: [DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 2)], to: transcript, metadata: metadata())
        XCTAssertEqual(aligned.segments.map(\.id), [segmentID])
        XCTAssertEqual(aligned.segments[0].displayText, "Human correction")
        XCTAssertEqual(aligned.segments[0].editedText, "Human correction")
    }

    func testNoSpeakerOverlapLeavesSegmentUnassigned() throws {
        let transcript = Transcript(recordingID: UUID(), segments: [TranscriptSegment(startTime: 10, endTime: 11, text: "Silence")], metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "1", modelID: TranscriptionModelManager.modelID))
        let aligned = try TranscriptSpeakerAligner.applying(intervals: [DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 1)], to: transcript, metadata: metadata())
        XCTAssertNil(aligned.segments[0].speakerID)
    }
}
