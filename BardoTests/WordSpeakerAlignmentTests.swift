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

    func testWordAtATurnBoundaryJoinsTheTurnItIsSpokenInto() {
        let first = Speaker.ID()
        let second = Speaker.ID()
        // Real SpeakerKit output: "Me" was attributed to the previous voice.
        let words = [
            AttributedTranscriptWord(word: TranscriptWord(startTime: 18.2, endTime: 18.9, text: "sprint."), speakerID: first),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 19.8, endTime: 19.9, text: "Me"), speakerID: first),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 19.9, endTime: 20.2, text: " parece"), speakerID: second),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 20.2, endTime: 20.5, text: " bien."), speakerID: second),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 20.6, endTime: 20.8, text: " Yo"), speakerID: second),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 20.8, endTime: 21.4, text: " me encargo."), speakerID: second)
        ]

        let smoothed = BardoWordSpeakerAligner.smoothingBoundaryWords(words)

        XCTAssertEqual(smoothed.map(\.speakerID), [first, second, second, second, second, second])
    }

    func testTrailingWordJoinsThePreviousTurn() {
        let first = Speaker.ID()
        let second = Speaker.ID()
        let words = [
            AttributedTranscriptWord(word: TranscriptWord(startTime: 0.2, endTime: 1.0, text: "Eso es todo."), speakerID: first),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 1.0, endTime: 1.4, text: " Muchas"), speakerID: first),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 1.4, endTime: 1.7, text: " gracias"), speakerID: second),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 3.0, endTime: 3.5, text: "Hola"), speakerID: second),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 3.5, endTime: 3.9, text: " a todos"), speakerID: second)
        ]

        let smoothed = BardoWordSpeakerAligner.smoothingBoundaryWords(words)

        XCTAssertEqual(smoothed.map(\.speakerID), [first, first, first, second, second])
    }

    func testOpeningWordsOfTheConversationKeepTheirSpeaker() {
        let first = Speaker.ID()
        let second = Speaker.ID()
        let words = [
            AttributedTranscriptWord(word: TranscriptWord(startTime: 0, endTime: 0.4, text: "Hello."), speakerID: first),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 0.4, endTime: 0.8, text: " Hi"), speakerID: second),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 0.8, endTime: 1.1, text: " there."), speakerID: second)
        ]

        let smoothed = BardoWordSpeakerAligner.smoothingBoundaryWords(words)

        XCTAssertEqual(smoothed.map(\.speakerID), [first, second, second])
    }

    func testShortReplyWithPausesOnBothSidesKeepsItsSpeaker() {
        let first = Speaker.ID()
        let second = Speaker.ID()
        let words = [
            AttributedTranscriptWord(word: TranscriptWord(startTime: 0, endTime: 0.8, text: "¿Listo?"), speakerID: first),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 1.4, endTime: 1.7, text: "Sí."), speakerID: second),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 2.4, endTime: 2.9, text: "Bien."), speakerID: first)
        ]

        let smoothed = BardoWordSpeakerAligner.smoothingBoundaryWords(words)

        XCTAssertEqual(smoothed.map(\.speakerID), [first, second, first])
    }

    func testQuickExchangeOfShortPhrasesKeepsBothSpeakers() {
        let first = Speaker.ID()
        let second = Speaker.ID()
        let words = [
            AttributedTranscriptWord(word: TranscriptWord(startTime: 0.0, endTime: 1.0, text: "…el plan."), speakerID: first),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 1.5, endTime: 1.8, text: "¿Vale?"), speakerID: first),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 1.85, endTime: 2.2, text: "Vale."), speakerID: second),
            AttributedTranscriptWord(word: TranscriptWord(startTime: 2.8, endTime: 3.6, text: "Entonces…"), speakerID: second)
        ]

        let smoothed = BardoWordSpeakerAligner.smoothingBoundaryWords(words)

        XCTAssertEqual(smoothed.map(\.speakerID), [first, first, second, second])
    }
}
