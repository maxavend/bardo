import Foundation
import XCTest
@testable import Bardo

final class MultitrackPlaybackTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoMultitrack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        directoryURL = nil
    }

    @MainActor
    func testSeparateTracksShareOneTimeline() throws {
        let controller = try loadedController()

        XCTAssertTrue(controller.hasSeparateTracks)
        XCTAssertEqual(controller.duration, 0.9, accuracy: 0.03, "The later track ends the timeline")

        controller.seek(to: 0.5)
        XCTAssertEqual(controller.position, 0.5, accuracy: 0.01)

        XCTAssertTrue(controller.play())
        controller.pause()
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testFocusAndGainsBalanceTheTracks() throws {
        let controller = try loadedController()

        controller.setFocus(.microphone)
        XCTAssertEqual(controller.focus, .microphone)
        XCTAssertTrue(controller.focus.includes(.microphone))
        XCTAssertFalse(controller.focus.includes(.system))

        controller.setGain(1.4, for: .system)
        XCTAssertEqual(controller.systemGain, 1, "Gains stay within 0…1")
        controller.setGain(0.25, for: .microphone)
        XCTAssertEqual(controller.microphoneGain, 0.25)
    }

    @MainActor
    func testLoadingTheSameTracksAgainKeepsThePosition() throws {
        let controller = try loadedController()
        controller.seek(to: 0.4)

        XCTAssertTrue(controller.load(tracks: tracks))

        XCTAssertEqual(controller.position, 0.4, accuracy: 0.01)
    }

    @MainActor
    func testOneFileIsNotSeparateTracks() throws {
        let url = directoryURL.appendingPathComponent("Mix.wav")
        try AudioTestFixture.makeWAV(at: url, duration: 0.6)
        let controller = AudioPlaybackController()

        XCTAssertTrue(controller.load(url: url))
        XCTAssertFalse(controller.hasSeparateTracks)
    }

    private var tracks: [PlaybackTrack] {
        [
            PlaybackTrack(url: directoryURL.appendingPathComponent("Microphone.wav"), offset: 0, source: .microphone),
            PlaybackTrack(url: directoryURL.appendingPathComponent("System.wav"), offset: 0.3, source: .system)
        ]
    }

    @MainActor
    private func loadedController() throws -> AudioPlaybackController {
        try AudioTestFixture.makeWAV(at: tracks[0].url, duration: 0.6)
        try AudioTestFixture.makeWAV(at: tracks[1].url, duration: 0.6)
        let controller = AudioPlaybackController()
        XCTAssertTrue(controller.load(tracks: tracks))
        return controller
    }
}
