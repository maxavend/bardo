import Foundation
import XCTest
@testable import Bardo

final class ParakeetTranscriptNormalizationTests: XCTestCase {
    func testNormalizesSentencePieceTokensIntoTranscriptWords() throws {
        let recordingID = UUID()
        let selection = TranscriptionSelection(
            preset: .instant,
            backend: .parakeet,
            modelID: "parakeet-tdt-0.6b-v3"
        )
        let output = ParakeetTranscriptionOutput(
            text: "Hola mundo",
            duration: 2.5,
            tokenTimings: [
                .init(token: "▁Hola", startTime: 0.2, endTime: 0.7, confidence: 0.91),
                .init(token: "▁mun", startTime: 0.9, endTime: 1.2, confidence: 0.87),
                .init(token: "do", startTime: 1.2, endTime: 1.4, confidence: 0.83)
            ]
        )

        let transcript = try ParakeetTranscriptNormalizer.transcript(
            recordingID: recordingID,
            output: output,
            selection: selection
        )

        XCTAssertEqual(transcript.recordingID, recordingID)
        XCTAssertEqual(transcript.metadata.engine, "FluidAudio")
        XCTAssertEqual(transcript.metadata.engineVersion, "0.15.6")
        XCTAssertEqual(transcript.metadata.modelID, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(transcript.metadata.selection, selection)
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].text, "Hola mundo")
        XCTAssertEqual(transcript.segments[0].startTime, 0)
        XCTAssertEqual(transcript.segments[0].endTime, 2.5)
        let words = transcript.segments[0].words
        XCTAssertEqual(words.map(\.text), ["Hola", "mundo"])
        XCTAssertEqual(words.map(\.startTime), [0.2, 0.9])
        XCTAssertEqual(words.map(\.endTime), [0.7, 1.4])
        XCTAssertEqual(words[0].probability, 0.91)
        XCTAssertEqual(words[1].probability, 0.85, accuracy: 0.0001)
    }

    func testRejectsOutputWithoutReadableText() {
        let output = ParakeetTranscriptionOutput(text: " \n", duration: 1, tokenTimings: [])

        XCTAssertThrowsError(
            try ParakeetTranscriptNormalizer.transcript(
                recordingID: UUID(),
                output: output,
                selection: TranscriptionSelection(
                    preset: .instant,
                    backend: .parakeet,
                    modelID: "parakeet-tdt-0.6b-v3"
                )
            )
        ) { error in
            XCTAssertEqual(error as? RecordingTranscriptionError, .emptyTranscription)
        }
    }
}
