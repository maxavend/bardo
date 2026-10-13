import XCTest
@testable import Bardo

final class TranscriptionProgressCopyTests: XCTestCase {
    private typealias Copy = TranscriptionProgressCopy

    /// A model load that takes long explains the one-time optimisation and how long it has run.
    func testLongModelLoadExplainsTheFirstRunOptimization() {
        let quick = Copy.Context(stage: .loadingModel, fraction: nil, stageElapsed: 3)
        let slow = Copy.Context(stage: .loadingModel, fraction: nil, stageElapsed: 72)
        XCTAssertNotEqual(Copy.detail(for: quick), Copy.detail(for: slow))
        XCTAssertTrue(Copy.thinkingLines(for: slow).contains("Lleva 1:12 optimizándose"))
        XCTAssertFalse(Copy.thinkingLines(for: quick).contains { $0.contains("optimizándose") })
    }

    /// While Whisper listens, the lines say where it is and how long is left.
    func testTranscribingLinesCarryPositionPercentAndEstimate() {
        let context = Copy.Context(
            stage: .transcribing, fraction: 0.25, processedAudio: 556, audioDuration: 2_226, stageElapsed: 60
        )
        let lines = Copy.thinkingLines(for: context)
        XCTAssertEqual(lines.first, "Transcribiendo · 9:16 de 37:06")
        XCTAssertTrue(lines.contains("Va en el 25 % de la conversación"))
        XCTAssertTrue(lines.contains("Quedan unos 3 minutos"))
    }

    func testLinesRotateEveryHold() {
        let context = Copy.Context(stage: .loadingModel, fraction: nil, stageElapsed: 0)
        var later = context
        later.stageElapsed = Copy.thinkingHold
        XCTAssertNotEqual(Copy.thinkingLine(for: context), Copy.thinkingLine(for: later))
    }

    func testEstimateWaitsForAReliablePace() {
        XCTAssertNil(Copy.remainingTime(fraction: 0.01, stageElapsed: 60))
        XCTAssertNil(Copy.remainingTime(fraction: 0.5, stageElapsed: 5))
        XCTAssertNil(Copy.remainingTime(fraction: nil, stageElapsed: 60))
        XCTAssertEqual(Copy.remainingTime(fraction: 0.9, stageElapsed: 90), "queda menos de un minuto")
        XCTAssertEqual(Copy.remainingTime(fraction: 0.5, stageElapsed: 70), "queda 1 minuto aproximadamente")
    }
}
