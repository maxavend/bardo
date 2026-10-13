import XCTest
@testable import Bardo

final class TranscriptionProgressCopyTests: XCTestCase {
    func testStepsFollowThePipeline() {
        XCTAssertEqual(
            [TranscriptionStage.preparingModel, .loadingModel, .transcribing, .saving].map(TranscriptionProgressCopy.step(for:)),
            [1, 2, 3, 4]
        )
    }

    /// A model load that takes long explains why instead of looking stuck.
    func testLongModelLoadExplainsTheFirstRunOptimization() {
        let quick = TranscriptionProgressCopy.detail(
            stage: .loadingModel, fraction: nil, processedAudio: 0, audioDuration: 0, stageElapsed: 3
        )
        let slow = TranscriptionProgressCopy.detail(
            stage: .loadingModel, fraction: nil, processedAudio: 0, audioDuration: 0, stageElapsed: 40
        )
        XCTAssertNotEqual(quick, slow)
        XCTAssertTrue(slow.contains("minutos"))
    }

    func testTranscribingShowsHeardAudioAndAnEstimate() {
        let detail = TranscriptionProgressCopy.detail(
            stage: .transcribing, fraction: 0.25, processedAudio: 556, audioDuration: 2_226, stageElapsed: 60
        )
        XCTAssertTrue(detail.hasPrefix("9:16 de 37:06"), detail)
        XCTAssertTrue(detail.contains("quedan unos 3 min"), detail)
    }

    func testEstimateWaitsForAReliablePace() {
        XCTAssertNil(TranscriptionProgressCopy.remainingTime(fraction: 0.01, stageElapsed: 60))
        XCTAssertNil(TranscriptionProgressCopy.remainingTime(fraction: 0.5, stageElapsed: 5))
        XCTAssertNil(TranscriptionProgressCopy.remainingTime(fraction: nil, stageElapsed: 60))
        XCTAssertEqual(TranscriptionProgressCopy.remainingTime(fraction: 0.9, stageElapsed: 90), "queda menos de un minuto")
        XCTAssertEqual(TranscriptionProgressCopy.remainingTime(fraction: 0.5, stageElapsed: 70), "queda 1 minuto aproximadamente")
    }
}
