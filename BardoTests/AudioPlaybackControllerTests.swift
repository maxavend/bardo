import Combine
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

        let deadline = ContinuousClock.now + .seconds(2)
        while await MainActor.run(body: { controller.isPlaying }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        await MainActor.run {
            XCTAssertFalse(controller.isPlaying)
            XCTAssertEqual(controller.position, controller.duration, accuracy: 0.06)
        }
    }

    @MainActor
    func testTimelineTicksDoNotRepublishEntirePlaybackController() async throws {
        let url = directoryURL.appendingPathComponent("StableToolbar.wav")
        try AudioTestFixture.makeWAV(at: url, duration: 1.2)

        let controller = AudioPlaybackController()
        let counter = PublicationCounter()
        let cancellable = controller.objectWillChange.sink {
            counter.increment()
        }
        defer { cancellable.cancel() }

        XCTAssertTrue(controller.load(url: url))
        XCTAssertTrue(controller.play())
        counter.reset()

        let startingPosition = controller.timeline.position
        try await Task.sleep(for: .milliseconds(450))
        let endingPosition = controller.timeline.position
        let publications = counter.value

        XCTAssertGreaterThan(endingPosition, startingPosition + 0.2)
        XCTAssertLessThanOrEqual(
            publications,
            1,
            "10 Hz timeline progress must not invalidate the whole detail/toolbar hierarchy"
        )

        controller.pause()
    }

    func testLoadingAnotherRecordingStopsPreviousAndResetsPlaybackState() async throws {
        let firstURL = directoryURL.appendingPathComponent("First.wav")
        let secondURL = directoryURL.appendingPathComponent("Second.wav")
        try AudioTestFixture.makeWAV(at: firstURL, duration: 0.8)
        try AudioTestFixture.makeWAV(at: secondURL, duration: 0.3)
        let controller = await MainActor.run { AudioPlaybackController() }

        await MainActor.run {
            controller.load(url: firstURL)
            controller.seek(to: 0.2)
            XCTAssertTrue(controller.play())
            XCTAssertTrue(controller.isPlaying)

            controller.load(url: secondURL)
            XCTAssertTrue(controller.isLoaded)
            XCTAssertFalse(controller.isPlaying)
            XCTAssertEqual(controller.position, 0, accuracy: 0.001)
            XCTAssertEqual(controller.duration, 0.3, accuracy: 0.03)
            XCTAssertNil(controller.errorMessage)
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

private final class PublicationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storage = 0
        lock.unlock()
    }
}
