import XCTest
@testable import Bardo

final class TranscriptTextSanitizerTests: XCTestCase {
    func testRemovesWhisperControlAndTimestampTokens() {
        let raw = "<|startoftranscript|><|transcribe|><|0.00|> Hola, bueno <|6.58|>"

        XCTAssertEqual(
            TranscriptTextSanitizer.sanitize(raw),
            "Hola, bueno"
        )
    }

    func testCollapsesWhitespaceAfterRemovingTokens() {
        let raw = "  Hola   <|6.58|>   y ver si esto funciona.  "

        XCTAssertEqual(
            TranscriptTextSanitizer.sanitize(raw),
            "Hola y ver si esto funciona."
        )
    }

    func testNormalizesProductVocabularyAndPunctuationWithoutParaphrasing() {
        let raw = "  figma tiene un anti-state ... y un support in text , después hand-off.  "

        XCTAssertEqual(
            TranscriptTextSanitizer.normalizeRecognizedText(raw),
            "Figma tiene un empty state… Y un supporting text, después handoff."
        )
    }

    func testCapitalizesSentenceStartsButPreservesExistingWords() {
        XCTAssertEqual(
            TranscriptTextSanitizer.normalizeRecognizedText("hola equipo. revisemos UX y UI."),
            "Hola equipo. Revisemos UX y UI."
        )
    }

    func testDisplayTextSanitizesLegacyStoredSegments() {
        let segment = TranscriptSegment(
            startTime: 0,
            endTime: 4,
            text: "<|0.00|> Texto visible <|4.00|>"
        )

        XCTAssertEqual(segment.displayText, "Texto visible")
    }

    func testRecognitionLoopKeepsOtherWordsAndTheirTimestamps() {
        let before = TranscriptWord(startTime: 3, endTime: 3.2, text: "Bueno,")
        let repeats = (0..<34).map { index in
            TranscriptWord(startTime: 3.2, endTime: 3.2, text: index.isMultiple(of: 2) ? "no." : "No.")
        }
        let after = TranscriptWord(startTime: 3.4, endTime: 3.7, text: "Seguimos.")
        let words = [before] + repeats + [after]
        let segment = TranscriptSegment(startTime: 3, endTime: 3.7, text: words.map(\.text).joined(separator: " "), words: words)

        let cleaned = TranscriptTextSanitizer.removingRecognitionLoop(from: segment)

        XCTAssertEqual(cleaned.id, segment.id)
        XCTAssertEqual(cleaned.words, [before] + Array(repeats.prefix(3)) + [after])
        XCTAssertEqual(cleaned.displayText, "Bueno, no. No. no. Seguimos.")
    }

    func testNormallyTimedRepetitionAndManualEditsArePreserved() {
        let words = (0..<12).map {
            TranscriptWord(startTime: Double($0) * 0.3, endTime: Double($0) * 0.3 + 0.2, text: "No.")
        }
        var segment = TranscriptSegment(startTime: 0, endTime: 4, text: words.map(\.text).joined(separator: " "), words: words)
        XCTAssertEqual(TranscriptTextSanitizer.removingRecognitionLoop(from: segment), segment)

        segment.words = words.map { TranscriptWord(startTime: 0, endTime: 0, text: $0.text) }
        segment.editedText = "No, gracias."
        XCTAssertEqual(TranscriptTextSanitizer.removingRecognitionLoop(from: segment), segment)
    }
}
