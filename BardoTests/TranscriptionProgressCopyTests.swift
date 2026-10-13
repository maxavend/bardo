import XCTest
@testable import Bardo

final class TranscriptionProgressCopyTests: XCTestCase {
    private typealias Copy = TranscriptionProgressCopy

    /// Each stage says what is happening in two calm lines; a long load is the
    /// one-time optimisation and says so.
    func testStagesUseTwoCalmLines() {
        let quick = Copy.Context(stage: .loadingModel, fraction: nil, stageElapsed: 3)
        let slow = Copy.Context(stage: .loadingModel, fraction: nil, stageElapsed: 40)
        XCTAssertEqual(Copy.thinkingLines(for: quick).count, 2)
        XCTAssertEqual(Copy.thinkingLines(for: slow).first, "Optimizando el modelo para tu Mac")
        XCTAssertNotEqual(Copy.detail(for: quick), Copy.detail(for: slow))
    }

    func testLinesRestBeforeChanging() {
        let start = Copy.Context(stage: .transcribing, fraction: nil, stageElapsed: 0)
        var almost = start
        almost.stageElapsed = Copy.thinkingHold - 0.1
        var next = start
        next.stageElapsed = Copy.thinkingHold
        XCTAssertGreaterThanOrEqual(Copy.thinkingHold, 4)
        XCTAssertEqual(Copy.thinkingLine(for: start), Copy.thinkingLine(for: almost))
        XCTAssertNotEqual(Copy.thinkingLine(for: start), Copy.thinkingLine(for: next))
    }

    /// The measurable part goes on the right: audio heard and percentage.
    func testFiguresShowAudioHeardAndPercentage() {
        let transcribing = Copy.Context(
            stage: .transcribing, fraction: 0.04, processedAudio: 90, audioDuration: 2_226, stageElapsed: 30
        )
        XCTAssertEqual(Copy.figures(for: transcribing), "1:30 de 37:06 · 4 %")
        XCTAssertEqual(Copy.figures(for: Copy.Context(stage: .preparingModel, fraction: 0.34)), "34 %")
        XCTAssertNil(Copy.figures(for: Copy.Context(stage: .loadingModel, fraction: nil)))
    }
}
