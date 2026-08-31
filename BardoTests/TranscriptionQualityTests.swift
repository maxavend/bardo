import XCTest
@testable import Bardo

final class TranscriptionQualityTests: XCTestCase {
    func testInvalidStoredValueFallsBackToBalanced() {
        XCTAssertEqual(TranscriptionQuality.resolve(nil), .balanced)
        XCTAssertEqual(TranscriptionQuality.resolve("future-model"), .balanced)
    }

    func testQualityMapsToStableModelIdentifiers() {
        XCTAssertEqual(
            TranscriptionQuality.instant.modelID,
            ParakeetTranscriptionService.modelID
        )
        XCTAssertEqual(
            TranscriptionQuality.balanced.modelID,
            TranscriptionModelManager.fastModelID
        )
        XCTAssertEqual(
            TranscriptionQuality.maximum.modelID,
            TranscriptionModelManager.maximumAccuracyModelID
        )
    }

    func testEveryQualityHasAStorageEstimate() {
        for quality in TranscriptionQuality.allCases {
            XCTAssertGreaterThan(quality.approximateDownloadBytes, 0)
        }
    }

    func testParakeetFallbackStillProducesAPlayableSegment() {
        let segments = ParakeetTranscriptBuilder.segments(
            tokenTimings: [],
            fallbackText: "  Hola mundo.  ",
            duration: 8.5
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hola mundo.")
        XCTAssertEqual(segments[0].startTime, 0)
        XCTAssertEqual(segments[0].endTime, 8.5, accuracy: 0.001)
    }
}
