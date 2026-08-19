import Foundation
import XCTest
@testable import Bardo

final class AudioPlaybackControllerTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPlaybackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        directoryURL = nil
    }

    func testPlayerLoadsPlaysPausesSeeksAndFinishesCoherently() async throws {
        let url = directoryURL.appendingPathComponent("Playback.wav")
        try AudioTestFixture.makeWAV(at: url, duration: 0.6)
        let controller = await MainActor.run { AudioPlaybackController() }

        await MainActor.run {
            controller.load(url: url)
            XCTAssertTrue(controller.isLoaded)
            XCTAssertNil(controller.errorMessage)
            XCTAssertEqual(controller.duration, 0.6, accuracy: 0.03)

            controller.seek(to: 0.15)
            XCTAssertEqual(controller.position, 0.15, accuracy: 0.02)
            XCTAssertTrue(controller.play())
            XCTAssertTrue(controller.isPlaying)
        }

        try await Task.sleep(for: .milliseconds(120))

        await MainActor.run {
            controller.pause()
            XCTAssertFalse(controller.isPlaying)
            XCTAssertGreaterThanOrEqual(controller.position, 0.15)
            XCTAssertLessThan(controller.position, controller.duration)

            controller.seek(to: 0.52)
            XCTAssertEqual(controller.position, 0.52, accuracy: 0.02)
            XCTAssertTrue(controller.play())
        }

        try await Task.sleep(for: .milliseconds(250))

        await MainActor.run {
            XCTAssertFalse(controller.isPlaying)
            XCTAssertEqual(controller.position, controller.duration, accuracy: 0.06)
        }
    }

    func testMissingAndCorruptFilesProduceControlledPlaybackErrors() async throws {
        let missingURL = directoryURL.appendingPathComponent("Missing.wav")
        let corruptURL = directoryURL.appendingPathComponent("Corrupt.wav")
        try Data("not audio".utf8).write(to: corruptURL)
        let controller = await MainActor.run { AudioPlaybackController() }

        await MainActor.run {
            controller.load(url: missingURL)
            XCTAssertFalse(controller.isLoaded)
            XCTAssertNotNil(controller.errorMessage)

            controller.load(url: corruptURL)
            XCTAssertFalse(controller.isLoaded)
            XCTAssertNotNil(controller.errorMessage)
        }
    }
}
