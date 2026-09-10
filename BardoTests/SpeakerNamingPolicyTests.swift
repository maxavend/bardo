import Foundation
import XCTest
@testable import Bardo

final class SpeakerNamingPolicyTests: XCTestCase {
    func testOneSpeakerIsNonActionableAndDoesNotOpenNamingFlow() {
        let transcript = makeTranscript(speakers: [Speaker(id: UUID())])

        XCTAssertEqual(
            SpeakerNamingPolicy.presentation(for: transcript),
            .singleSpeaker
        )
        XCTAssertFalse(SpeakerNamingPolicy.shouldOpenNamingFlow(after: transcript))
    }

    func testTwoSpeakersShowParticipantsAndAllowNamingFlow() {
        let transcript = makeTranscript(speakers: [Speaker(id: UUID()), Speaker(id: UUID())])

        XCTAssertEqual(
            SpeakerNamingPolicy.presentation(for: transcript),
            .participants(2)
        )
        XCTAssertTrue(SpeakerNamingPolicy.shouldOpenNamingFlow(after: transcript))
    }

    func testNoSpeakersRequestsSpeakerIdentification() {
        let transcript = makeTranscript()

        XCTAssertEqual(
            SpeakerNamingPolicy.presentation(for: transcript),
            .identifySpeakers
        )
        XCTAssertFalse(SpeakerNamingPolicy.shouldOpenNamingFlow(after: transcript))
    }

    private func makeTranscript(speakers: [Speaker] = []) -> Transcript {
        Transcript(
            recordingID: UUID(),
            speakers: speakers,
            metadata: TranscriptMetadata(
                engine: "test",
                engineVersion: "1",
                modelID: "test"
            )
        )
    }
}
