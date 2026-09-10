import XCTest
@testable import Bardo

final class WordSpeakerAlignmentTests: XCTestCase {
    func testEachWordUsesTheSpeakerWithGreatestTemporalOverlap() {
        let words = [
            TranscriptWord(startTime: 0, endTime: 0.4, text: "One"),
            TranscriptWord(startTime: 0.5, endTime: 1.8, text: " two"),
            TranscriptWord(startTime: 1.9, endTime: 2.8, text: " three")
        ]
        let intervals = [
            DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 0.45),
            DiarizationInterval(speakerIndex: 1, startTime: 0.45, endTime: 3)
        ]

        let attributed = BardoWordSpeakerAligner.align(words: words, intervals: intervals)

        XCTAssertEqual(attributed.map(\.speakerIndex), [0, 1, 1])
        XCTAssertEqual(attributed.map(\.word.text), words.map(\.text))
    }

    func testPointTimestampUsesMidpointFallbackAndMissingEvidenceStaysNil() {
        let words = [
            TranscriptWord(startTime: 2, endTime: 2, text: "point"),
            TranscriptWord(startTime: 10, endTime: 11, text: "unknown")
        ]
        let intervals = [DiarizationInterval(speakerIndex: 3, startTime: 1, endTime: 3)]

        let attributed = BardoWordSpeakerAligner.align(words: words, intervals: intervals)

        XCTAssertEqual(attributed.map(\.speakerIndex), [3, nil])
    }
}
