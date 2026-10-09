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
}
