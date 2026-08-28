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

    func testDisplayTextSanitizesLegacyStoredSegments() {
        let segment = TranscriptSegment(
            startTime: 0,
            endTime: 4,
            text: "<|0.00|> Texto visible <|4.00|>"
        )

        XCTAssertEqual(segment.displayText, "Texto visible")
    }
}
