import Foundation
import XCTest
@testable import Bardo

final class TranscriptPresentationTests: XCTestCase {
    func testConsecutiveSegmentsFromSameSpeakerBecomeOneReadingBlock() {
        let speakerID = UUID()
        let segments = [
            segment(start: 0, end: 4, speakerID: speakerID, text: "Sácalo de este sistema"),
            segment(start: 4.6, end: 7, speakerID: speakerID, text: "y ponlo en otro"),
            segment(start: 8, end: 10, speakerID: speakerID, text: "para no perderlo.")
        ]

        let blocks = TranscriptReadingBlockBuilder.blocks(from: segments)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].startTime, 0)
        XCTAssertEqual(blocks[0].endTime, 10)
        XCTAssertEqual(blocks[0].speakerID, speakerID)
        XCTAssertEqual(blocks[0].text, "Sácalo de este sistema y ponlo en otro para no perderlo.")
        XCTAssertEqual(blocks[0].segments.count, 3)
    }

    func testFiveSecondSilenceStartsANewBlockEvenForSameSpeaker() {
        let speakerID = UUID()
        let segments = [
            segment(start: 0, end: 5, speakerID: speakerID, text: "Primera idea."),
            segment(start: 10, end: 12, speakerID: speakerID, text: "Idea nueva.")
        ]

        let blocks = TranscriptReadingBlockBuilder.blocks(from: segments)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.text), ["Primera idea.", "Idea nueva."])
    }

    func testSpeakerChangeAlwaysStartsANewBlock() {
        let firstSpeaker = UUID()
        let secondSpeaker = UUID()
        let segments = [
            segment(start: 0, end: 4, speakerID: firstSpeaker, text: "¿Qué te parece?"),
            segment(start: 4.1, end: 6, speakerID: secondSpeaker, text: "Me parece bien.")
        ]

        let blocks = TranscriptReadingBlockBuilder.blocks(from: segments)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].speakerID, firstSpeaker)
        XCTAssertEqual(blocks[1].speakerID, secondSpeaker)
    }

    func testUndiarizedSegmentsStillGroupByPauseInsteadOfDecoderSegment() {
        let segments = [
            segment(start: 0, end: 2, text: "Uno."),
            segment(start: 2.2, end: 4, text: "Dos."),
            segment(start: 11, end: 13, text: "Tres.")
        ]

        let blocks = TranscriptReadingBlockBuilder.blocks(from: segments)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "Uno. Dos.")
        XCTAssertEqual(blocks[1].text, "Tres.")
    }

    func testPlaybackMappingHighlightsSpeechButNotLongSilence() {
        let segments = [
            segment(start: 0, end: 4, text: "Primer bloque."),
            segment(start: 10, end: 12, text: "Segundo bloque.")
        ]
        let blocks = TranscriptReadingBlockBuilder.blocks(from: segments)

        XCTAssertEqual(
            TranscriptPlaybackMapping.activeBlockID(at: 2, in: blocks),
            blocks[0].id
        )
        XCTAssertNil(TranscriptPlaybackMapping.activeBlockID(at: 7, in: blocks))
        XCTAssertEqual(
            TranscriptPlaybackMapping.activeBlockID(at: 10.2, in: blocks),
            blocks[1].id
        )
    }

    func testManualEditStatusIsPreservedAtBlockLevel() {
        let original = TranscriptSegment(
            startTime: 0,
            endTime: 2,
            text: "Original",
            editedText: "Corregido"
        )
        let next = segment(start: 2.2, end: 4, text: "continúa.")

        let block = TranscriptReadingBlockBuilder.blocks(from: [original, next])[0]

        XCTAssertTrue(block.hasManualEdits)
        XCTAssertEqual(block.text, "Corregido continúa.")
    }

    private func segment(
        start: TimeInterval,
        end: TimeInterval,
        speakerID: Speaker.ID? = nil,
        text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            startTime: start,
            endTime: end,
            speakerID: speakerID,
            text: text
        )
    }
}
