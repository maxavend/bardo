import Foundation
import XCTest
@testable import Bardo

final class Phase2IntegrationTests: XCTestCase {
    private var baseURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase2Integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseURL {
            try? FileManager.default.removeItem(at: baseURL)
        }
        baseURL = nil
    }

    func testImportedAudioRemainsAvailableAndPlayableAfterOriginalDeletionAndStateRestart() async throws {
        let libraryURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        let externalURL = baseURL.appendingPathComponent("External.wav")
        try AudioTestFixture.makeWAV(at: externalURL, sampleRate: 11_025, channelCount: 1, duration: 0.4)

        let initialStore = RecordingStore(rootURL: libraryURL)
        let imported = try await AudioImportService(store: initialStore).importFile(at: externalURL)
        try FileManager.default.removeItem(at: externalURL)

        let restartedStore = RecordingStore(rootURL: libraryURL)
        let restartedModel = await MainActor.run {
            LibraryViewModel(store: restartedStore)
        }
        await restartedModel.reload()

        let firstRecording = await MainActor.run { restartedModel.recordings.first }
        let restartedRecording = try XCTUnwrap(firstRecording)
        XCTAssertRecordingPersistenceEqual(restartedRecording, imported)

        await MainActor.run {
            XCTAssertEqual(restartedModel.recordings.count, 1)
            XCTAssertEqual(restartedModel.selection, imported.id)
            XCTAssertTrue(restartedModel.issues.isEmpty)
            XCTAssertTrue(restartedModel.playback.isLoaded)
            XCTAssertEqual(restartedModel.playback.duration, 0.4, accuracy: 0.03)
            XCTAssertTrue(restartedModel.playback.play())
            restartedModel.playback.pause()
            XCTAssertFalse(restartedModel.playback.isPlaying)
        }
    }
}
