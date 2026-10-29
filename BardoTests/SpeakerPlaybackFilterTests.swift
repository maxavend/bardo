import XCTest
@testable import Bardo

final class SpeakerPlaybackFilterTests: XCTestCase {
    private let valentina = Speaker(name: "Valentina")
    private let diego = Speaker(name: "Diego")
    private let you = Speaker(role: .localUser)

    private func transcript(_ turns: [(TimeInterval, TimeInterval, Speaker?)]) -> Transcript {
        Transcript(
            recordingID: UUID(),
            speakers: [valentina, diego, you],
            segments: turns.map { TranscriptSegment(startTime: $0.0, endTime: $0.1, speakerID: $0.2?.id, text: "…") },
            metadata: TranscriptMetadata(engine: "test", engineVersion: "1", modelID: "test")
        )
    }

    func testOnlyTheChosenParticipantsTurnsPlay() {
        let transcript = transcript([(2, 10, valentina), (10, 20, diego), (20, 30, valentina), (30, 40, you)])

        let skipped = SpeakerPlaybackFilter.skippedRanges(of: transcript, keeping: [valentina.id], duration: 45)

        XCTAssertEqual(skipped, [0...1.75, 10.25...19.75, 30.25...45])
    }

    func testTwoParticipantsCanBeHeardTogether() {
        let transcript = transcript([(0, 10, valentina), (10, 20, diego), (20, 30, you)])

        let skipped = SpeakerPlaybackFilter.skippedRanges(of: transcript, keeping: [valentina.id, diego.id], duration: 30)

        XCTAssertEqual(skipped, [20.25...30])
    }

    func testShortGapsBetweenKeptTurnsPlayThrough() {
        // Diego's quick "sí" between two of Valentina's turns is not worth a jump.
        let transcript = transcript([(0, 10, valentina), (10.2, 10.9, diego), (11, 20, valentina)])

        let skipped = SpeakerPlaybackFilter.skippedRanges(of: transcript, keeping: [valentina.id], duration: 20)

        XCTAssertEqual(skipped, [])
    }

    func testTextNobodySaidIsSkipped() {
        let transcript = transcript([(0, 5, valentina), (5, 15, nil), (15, 20, valentina)])

        let skipped = SpeakerPlaybackFilter.skippedRanges(of: transcript, keeping: [valentina.id], duration: 20)

        XCTAssertEqual(skipped, [5.25...14.75])
    }

    func testSilencesAndOtherVoicesJoinIntoOneSkip() {
        let merged = SpeakerPlaybackFilter.merged([10...20, 0...2, 18...25, 25...30, 40...41])

        XCTAssertEqual(merged, [0...2, 10...30, 40...41])
    }
}
