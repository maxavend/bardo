import Combine
import XCTest
@testable import Bardo

@MainActor
final class RecordingMenuBarTests: XCTestCase {
    private func state(paused: Bool = false, muted: Bool = false) -> RecordingMenuBarState {
        RecordingMenuBarState(
            isPaused: paused,
            commands: BardoCaptureCommandState(
                canStart: false,
                canPause: !paused,
                canResume: paused,
                canStop: true,
                canMute: true,
                isMuted: muted,
                canMark: true
            )
        )
    }

    func testStatusSaysWhatTheSymbolMeans() {
        XCTAssertEqual(state().status, "Grabando")
        XCTAssertEqual(state(muted: true).status, "Micrófono silenciado")
        XCTAssertEqual(state(paused: true).status, "Grabación en pausa")
        XCTAssertEqual(state(paused: true, muted: true).status, "Grabación en pausa", "Pause says more than mute")
    }

    func testClockShowsWholeSecondsHeard() {
        let clock = RecordingMenuBarClock()
        var heard: TimeInterval = 65.9
        clock.run(position: { heard }, isPaused: true)
        XCTAssertEqual(clock.seconds, 65)
        XCTAssertEqual(clock.text, "1:05")

        heard = 3_725
        clock.refresh()
        XCTAssertEqual(clock.text, "1:02:05")

        heard = .nan
        clock.refresh()
        XCTAssertEqual(clock.seconds, 0)

        heard = 12
        clock.stop()
        clock.refresh()
        XCTAssertEqual(clock.seconds, 0, "A stopped clock forgets the recording")
    }

    func testClockPublishesOnlyWhenTheSecondChanges() {
        let clock = RecordingMenuBarClock()
        var heard: TimeInterval = 1.1
        clock.run(position: { heard }, isPaused: true)
        var changes = 0
        let subscription = clock.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        heard = 1.6
        clock.refresh()
        heard = 1.99
        clock.refresh()
        XCTAssertEqual(changes, 0)

        heard = 2.01
        clock.refresh()
        XCTAssertEqual(changes, 1)
    }

    func testClockTicksWhileRecordingAndHoldsWhilePaused() async throws {
        let clock = RecordingMenuBarClock()
        var heard: TimeInterval = 0
        clock.run(position: { heard }, isPaused: false)
        heard = 4.2
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(clock.seconds, 4)

        clock.run(position: { heard }, isPaused: true)
        heard = 9
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(clock.seconds, 4, "Paused, the time holds still")
        clock.stop()
    }

    func testItemAppearsWithTheRecordingAndLeavesWithIt() {
        let menuBar = RecordingMenuBar()
        var changes = 0
        let subscription = menuBar.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        menuBar.update(state(), position: { 7.5 })
        XCTAssertEqual(menuBar.state, state())
        XCTAssertEqual(menuBar.clock.seconds, 7)

        // The window re-sends the same state as it redraws; the menu bar keeps still.
        menuBar.update(state(), position: { 8 })
        XCTAssertEqual(changes, 1)

        menuBar.update(state(paused: true), position: { 8 })
        XCTAssertEqual(menuBar.state?.isPaused, true)

        menuBar.update(nil, position: { 0 })
        XCTAssertNil(menuBar.state)
        XCTAssertEqual(menuBar.clock.seconds, 0)
    }

    func testRecordingSymbolKeepsItsRedAndPauseFollowsTheMenuBar() {
        let recording = RecordingMenuBarLabel.symbol(isPaused: false, status: "Grabando")
        XCTAssertFalse(recording.isTemplate)
        XCTAssertEqual(recording.accessibilityDescription, "Grabando")
        XCTAssertTrue(RecordingMenuBarLabel.symbol(isPaused: true, status: "Grabación en pausa").isTemplate)
    }
}
