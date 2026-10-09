import XCTest
@testable import Bardo

final class ConversationTurnBuilderTests: XCTestCase {
    private let speakerA = UUID()
    private let speakerB = UUID()

    func testSameSpeakerWithBriefPauseStaysInOneTurn() {
        let words = [
            attributed("Entonces", 0, 0.2, speaker: speakerA),
            attributed(" lo", 0.25, 0.4, speaker: speakerA),
            attributed(" revisamos.", 0.75, 1.0, speaker: speakerA)
        ]

        let turns = BardoConversationTurnBuilder.build(from: words)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "Entonces lo revisamos.")
        XCTAssertEqual(turns[0].startTime, 0)
        XCTAssertEqual(turns[0].endTime, 1.0)
    }

    func testSameSpeakerWithLongPauseStartsAnotherTurn() {
        let words = [
            attributed("Primero.", 0, 0.3, speaker: speakerA),
            attributed("Después.", 1.6, 1.9, speaker: speakerA)
        ]

        let turns = BardoConversationTurnBuilder.build(from: words)

        XCTAssertEqual(turns.map(\.text), ["Primero.", "Después."])
    }

    func testSpeakerChangeAlwaysCreatesBoundaryIncludingBackchannel() {
        let words = [
            attributed("Yo creo que", 0, 0.5, speaker: speakerA),
            attributed(" perdón", 0.55, 0.75, speaker: speakerB),
            attributed(" sí, dime.", 0.8, 1.2, speaker: speakerA)
        ]

        let turns = BardoConversationTurnBuilder.build(from: words)

        XCTAssertEqual(turns.map(\.speakerID), [speakerA, speakerB, speakerA])
        XCTAssertEqual(turns.map(\.text), ["Yo creo que", "perdón", "sí, dime."])
    }

    func testLongMonologueSplitsAtNaturalSentenceBoundary() {
        let words = [
            attributed("Esta es una explicación bastante larga.", 0, 31, speaker: speakerA),
            attributed("Y esta es la siguiente idea.", 31.7, 33, speaker: speakerA)
        ]

        let turns = BardoConversationTurnBuilder.build(from: words)

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].text, "Esta es una explicación bastante larga.")
    }

    private func attributed(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        speaker: UUID?
    ) -> AttributedTranscriptWord {
        AttributedTranscriptWord(
            word: TranscriptWord(startTime: start, endTime: end, text: text),
            speakerID: speaker
        )
    }
}
