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

    func testWordCuesMapWhisperWordTimestampsIntoCombinedBlockText() {
        let firstWord = TranscriptWord(startTime: 0.1, endTime: 0.4, text: " Hola")
        let secondWord = TranscriptWord(startTime: 0.45, endTime: 0.8, text: " mundo.")
        let thirdWord = TranscriptWord(startTime: 1.1, endTime: 1.4, text: " Otra")
        let fourthWord = TranscriptWord(startTime: 1.45, endTime: 1.8, text: " idea.")
        let segments = [
            segment(
                start: 0,
                end: 0.9,
                text: "Hola mundo.",
                words: [firstWord, secondWord]
            ),
            segment(
                start: 1,
                end: 2,
                text: "Otra idea.",
                words: [thirdWord, fourthWord]
            )
        ]

        let block = TranscriptReadingBlockBuilder.blocks(from: segments)[0]

        XCTAssertEqual(block.text, "Hola mundo. Otra idea.")
        XCTAssertEqual(block.wordCues.count, 4)
        XCTAssertEqual(String(block.text.charactersIn(block.wordCues[0].characterRange)), "Hola")
        XCTAssertEqual(String(block.text.charactersIn(block.wordCues[1].characterRange)), "mundo.")
        XCTAssertEqual(String(block.text.charactersIn(block.wordCues[2].characterRange)), "Otra")
        XCTAssertEqual(String(block.text.charactersIn(block.wordCues[3].characterRange)), "idea.")
        XCTAssertEqual(
            TranscriptPlaybackMapping.activeWordCue(at: 1.2, in: block)?.id,
            thirdWord.id
        )
    }

    func testWordCueMappingDoesNotGuessAgainstManuallyEditedText() {
        let originalWord = TranscriptWord(startTime: 0.1, endTime: 0.5, text: " Original")
        let edited = TranscriptSegment(
            startTime: 0,
            endTime: 1,
            text: "Original",
            words: [originalWord],
            editedText: "Corregido"
        )

        let block = TranscriptReadingBlockBuilder.blocks(from: [edited])[0]

        XCTAssertEqual(block.text, "Corregido")
        XCTAssertTrue(block.wordCues.isEmpty)
        XCTAssertNil(TranscriptPlaybackMapping.activeWordCue(at: 0.3, in: block))
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
        text: String,
        words: [TranscriptWord] = []
    ) -> TranscriptSegment {
        TranscriptSegment(
            startTime: start,
            endTime: end,
            speakerID: speakerID,
            text: text,
            words: words
        )
    }
}

private extension String {
    func charactersIn(_ range: Range<Int>) -> Substring {
        let lower = index(startIndex, offsetBy: range.lowerBound)
        let upper = index(startIndex, offsetBy: range.upperBound)
        return self[lower..<upper]
    }
}
