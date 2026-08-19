import Foundation
import XCTest

@testable import Bardo

final class Phase3IntegrationTests: XCTestCase {
    @MainActor
    func testMicrophoneCaptureBecomesLibraryPlaybackAndSurvivesRestart() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase3IntegrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let libraryURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        let stagingURL = baseURL.appendingPathComponent("Staging", isDirectory: true)

        let firstStore = RecordingStore(rootURL: libraryURL)
        let stagingStore = MicrophoneCaptureStagingStore(rootURL: stagingURL)
        let backend = IncrementalTestCaptureBackend()
        let controller = MicrophoneRecordingController(
            store: firstStore,
            stagingStore: stagingStore,
            permissionAuthorizer: TestMicrophonePermissionAuthorizer(status: .authorized),
            backend: backend
        )

        await controller.start()
        XCTAssertEqual(controller.phase, .recording)
        let stagedURL = try XCTUnwrap(backend.lastURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        let stopped = await controller.stop()
        let recording = try XCTUnwrap(stopped)
        let firstLibrary = LibraryViewModel(store: firstStore)
        await firstLibrary.reload()
        firstLibrary.selection = recording.id
        await firstLibrary.preparePlaybackForSelection()

        XCTAssertEqual(firstLibrary.selectedRecording?.id, recording.id)
        XCTAssertTrue(firstLibrary.playback.isLoaded)
        XCTAssertTrue(firstLibrary.playback.play())
        firstLibrary.playback.pause()

        let restartedStore = RecordingStore(rootURL: libraryURL)
        let restartedLibrary = LibraryViewModel(store: restartedStore)
        await restartedLibrary.reload()
        let restartedRecording = try XCTUnwrap(restartedLibrary.selectedRecording)
        XCTAssertRecordingPersistenceEqual(restartedRecording, recording)
        XCTAssertTrue(restartedLibrary.playback.isLoaded)
        XCTAssertTrue(restartedLibrary.playback.play())
        restartedLibrary.playback.pause()
        let finalRecoveryIssues = await MicrophoneCaptureStagingStore(rootURL: stagingURL).recoveryIssues()
        XCTAssertTrue(finalRecoveryIssues.isEmpty)
    }
}
