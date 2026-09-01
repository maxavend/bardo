import XCTest
@testable import Bardo

final class MeetingMinutesTranscriptFormatterTests: XCTestCase {
    func testFormattedLinesPreserveSpeakerNamesAndSourceTimes() {
        let speaker = Speaker(name: "Maxi")
        let transcript = Transcript(
            recordingID: UUID(),
            languageCode: "es",
            speakers: [speaker],
            segments: [
                TranscriptSegment(
                    startTime: 754.9,
                    endTime: 760,
                    speakerID: speaker.id,
                    text: "Entregamos el prototipo el viernes."
                )
            ],
            metadata: TranscriptMetadata(
                engine: "test",
                engineVersion: "1",
                modelID: "test"
            )
        )

        XCTAssertEqual(
            MeetingMinutesTranscriptFormatter.formattedLines(from: transcript),
            ["[t=754s | 00:12:34] Maxi: Entregamos el prototipo el viernes."]
        )
    }

    func testUnnamedSpeakersReceiveStableLabels() {
        let first = Speaker()
        let second = Speaker()
        let transcript = Transcript(
            recordingID: UUID(),
            speakers: [first, second],
            segments: [
                TranscriptSegment(startTime: 0, endTime: 1, speakerID: first.id, text: "Uno"),
                TranscriptSegment(startTime: 2, endTime: 3, speakerID: second.id, text: "Dos")
            ],
            metadata: TranscriptMetadata(
                engine: "test",
                engineVersion: "1",
                modelID: "test"
            )
        )

        XCTAssertEqual(
            MeetingMinutesTranscriptFormatter.formattedLines(from: transcript),
            [
                "[t=0s | 00:00:00] Speaker 1: Uno",
                "[t=2s | 00:00:02] Speaker 2: Dos"
            ]
        )
    }

    func testChunksStayWithinRequestedCharacterLimit() {
        let transcript = Transcript(
            recordingID: UUID(),
            segments: [
                TranscriptSegment(startTime: 0, endTime: 1, text: String(repeating: "a", count: 90)),
                TranscriptSegment(startTime: 2, endTime: 3, text: String(repeating: "b", count: 90))
            ],
            metadata: TranscriptMetadata(
                engine: "test",
                engineVersion: "1",
                modelID: "test"
            )
        )

        let chunks = MeetingMinutesTranscriptFormatter.chunks(from: transcript, maxCharacters: 64)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 64 })
        XCTAssertTrue(chunks.joined(separator: "\n").contains("aaaa"))
        XCTAssertTrue(chunks.joined(separator: "\n").contains("bbbb"))
    }
}
