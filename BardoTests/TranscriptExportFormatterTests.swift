import Foundation
import XCTest
@testable import Bardo

final class TranscriptExportFormatterTests: XCTestCase {
    func testUndiarizedTranscriptCopiesPlainReadableText() {
        let transcript = makeTranscript(
            speakers: [],
            segments: [
                TranscriptSegment(startTime: 0, endTime: 1, text: "Hola."),
                TranscriptSegment(startTime: 1.2, endTime: 2, text: "Seguimos.")
            ],
            diarized: false
        )

        XCTAssertEqual(TranscriptExportFormatter.string(from: transcript), "Hola.\nSeguimos.")
    }

    func testDiarizedTranscriptIncludesAutomaticSpeakerLabels() {
        let first = Speaker()
        let second = Speaker()
        let transcript = makeTranscript(
            speakers: [first, second],
            segments: [
                TranscriptSegment(startTime: 0, endTime: 2, speakerID: first.id, text: "Primera intervención."),
                TranscriptSegment(startTime: 2.2, endTime: 4, speakerID: second.id, text: "Segunda intervención.")
            ],
            diarized: true
        )

        let exported = TranscriptExportFormatter.string(from: transcript)
        XCTAssertTrue(exported.contains("Speaker 1:\nPrimera intervención."))
        XCTAssertTrue(exported.contains("Speaker 2:\nSegunda intervención."))
    }

    func testDiarizedTranscriptUsesRenamedSpeakers() {
        let franklin = Speaker(name: "Franklin")
        let maria = Speaker(name: "María")
        let transcript = makeTranscript(
            speakers: [franklin, maria],
            segments: [
                TranscriptSegment(startTime: 0, endTime: 2, speakerID: franklin.id, text: "Vamos con el deploy."),
                TranscriptSegment(startTime: 2.2, endTime: 4, speakerID: maria.id, text: "Perfecto.")
            ],
            diarized: true
        )

        XCTAssertEqual(
            TranscriptExportFormatter.string(from: transcript),
            "Franklin:\nVamos con el deploy.\n\nMaría:\nPerfecto."
        )
    }

    func testCopyWithoutSpeakersReturnsCleanTranscript() {
        let speaker = Speaker(name: "Franklin")
        let transcript = makeTranscript(
            speakers: [speaker],
            segments: [
                TranscriptSegment(startTime: 0, endTime: 1, speakerID: speaker.id, text: "Hola."),
                TranscriptSegment(startTime: 1.1, endTime: 2, speakerID: speaker.id, text: "Seguimos.")
            ],
            diarized: true
        )

        XCTAssertEqual(
            TranscriptExportFormatter.string(from: transcript, style: .withoutSpeakers),
            "Hola.\nSeguimos."
        )
    }

    func testCopyWithTimestampsKeepsSpeakerNamesWhenAvailable() {
        let speaker = Speaker(name: "María")
        let transcript = makeTranscript(
            speakers: [speaker],
            segments: [
                TranscriptSegment(startTime: 65, endTime: 67, speakerID: speaker.id, text: "Un minuto después.")
            ],
            diarized: true
        )

        XCTAssertEqual(
            TranscriptExportFormatter.string(from: transcript, style: .withTimestamps),
            "[1:05] María:\nUn minuto después."
        )
    }

    private func makeTranscript(
        speakers: [Speaker],
        segments: [TranscriptSegment],
        diarized: Bool
    ) -> Transcript {
        Transcript(
            recordingID: UUID(),
            languageCode: "es",
            speakers: speakers,
            segments: segments,
            metadata: TranscriptMetadata(engine: "Test", engineVersion: "1", modelID: "test"),
            diarizationMetadata: diarized
                ? DiarizationMetadata(engine: "SpeakerKit", engineVersion: "1", modelID: "test")
                : nil
        )
    }
}
