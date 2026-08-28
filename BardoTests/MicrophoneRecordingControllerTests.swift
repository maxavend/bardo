import Foundation
import XCTest

@testable import Bardo

final class MicrophoneRecordingControllerTests: XCTestCase {
    @MainActor
    func testSecondStartIsRejectedAndStopIsIdempotent() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        let controller = makeController(env: env, backend: backend)

        await controller.start()
        XCTAssertEqual(controller.phase, .recording)

        await controller.start()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(backend.startCount, 1)
        XCTAssertNotNil(controller.errorMessage)

        let firstStop = await controller.stop()
        XCTAssertNotNil(firstStop)
        let secondStop = await controller.stop()
        XCTAssertNil(secondStop)
        XCTAssertEqual(backend.stopCount, 1)
    }

    @MainActor
    func testPauseResumeAndStopFromPausedAreDeterministic() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        let controller = makeController(env: env, backend: backend)

        await controller.start()
        XCTAssertEqual(controller.phase, .recording)

        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(controller.isPaused)
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(backend.pauseCount, 1)

        controller.pause()
        XCTAssertEqual(backend.pauseCount, 1, "Repeated pause must be a no-op")

        controller.resume()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(backend.resumeCount, 1)

        controller.pause()
        let recording = await controller.stop()
        XCTAssertNotNil(recording, "Stopping from paused must still finalize the capture")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(backend.stopCount, 1)
    }

    @MainActor
    func testSeparateControllersCannotRecordConcurrently() async throws {
        let firstEnv = makeEnvironment()
        let secondEnv = makeEnvironment()
        defer {
            try? FileManager.default.removeItem(at: firstEnv.baseURL)
            try? FileManager.default.removeItem(at: secondEnv.baseURL)
        }
        let firstBackend = IncrementalTestCaptureBackend()
        let secondBackend = IncrementalTestCaptureBackend()
        let first = makeController(env: firstEnv, backend: firstBackend)
        let second = makeController(env: secondEnv, backend: secondBackend)

        await first.start()
        XCTAssertEqual(first.phase, .recording)

        await second.start()
        XCTAssertEqual(second.phase, .idle)
        XCTAssertEqual(secondBackend.startCount, 0)
        XCTAssertNotNil(second.errorMessage)

        _ = await first.stop()
    }

    @MainActor
    func testCaptureWritesBeforeStopUsesRecorderClockAndPublishesThroughRecordingStore() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        let controller = makeController(env: env, backend: backend)

        await controller.start()
        let stagedURL = try XCTUnwrap(backend.lastURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
        let stagedSize = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(stagedSize, 0, "Capture must write to disk while active")
        XCTAssertEqual(controller.inputDisplayName, "CI Test Microphone")

        backend.currentTime = 0.4
        controller.refreshElapsedTime()
        XCTAssertEqual(controller.elapsedTime, 0.4, accuracy: 0.0001)

        let stoppedRecording = await controller.stop()
        let recording = try XCTUnwrap(stoppedRecording)
        let asset = try XCTUnwrap(recording.audioAssets.first)
        XCTAssertEqual(recording.sources, [.microphone])
        XCTAssertEqual(asset.fileExtension, "wav")
        XCTAssertEqual(asset.metadata.sampleRate, 8_000, accuracy: 0.1)
        XCTAssertEqual(asset.metadata.channelCount, 1)
        XCTAssertGreaterThan(asset.metadata.duration, 0)
        XCTAssertEqual(try XCTUnwrap(recording.duration), asset.metadata.duration, accuracy: 0.0001)

        let managedURL = try await env.recordingStore.managedAudioURL(
            recordingID: recording.id,
            audioAssetID: asset.id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        let recoveryIssues = await env.stagingStore.recoveryIssues()
        XCTAssertTrue(recoveryIssues.isEmpty)
    }

    @MainActor
    func testBackendStartFailurePublishesNothingAndRemovesPreparation() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        backend.startError = AudioCaptureBackendError.startFailed
        let controller = makeController(env: env, backend: backend)

        await controller.start()

        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(backend.startCount, 1)
        let snapshot = try await env.recordingStore.loadLibrary()
        XCTAssertTrue(snapshot.recordings.isEmpty)
        XCTAssertTrue(snapshot.issues.isEmpty)
        let failureRecoveryIssues = await env.stagingStore.recoveryIssues()
        XCTAssertTrue(failureRecoveryIssues.isEmpty)
    }

    @MainActor
    func testUnexpectedInterruptionPreservesStagingWithoutFalseRecording() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        let controller = makeController(env: env, backend: backend)

        await controller.start()
        let stagedURL = try XCTUnwrap(backend.lastURL)
        backend.simulateInterruption("Input disconnected")

        XCTAssertEqual(controller.phase, .failed)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        let library = try await env.recordingStore.loadLibrary()
        XCTAssertTrue(library.recordings.isEmpty)

        let freshStagingStore = MicrophoneCaptureStagingStore(rootURL: env.stagingURL)
        let issues = await freshStagingStore.recoveryIssues()
        XCTAssertEqual(issues.count, 1)
    }

    @MainActor
    func testNormalTerminationFinalizesActiveRecording() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        let controller = makeController(env: env, backend: backend)

        await controller.start()
        XCTAssertEqual(controller.phase, .recording)

        await controller.prepareForApplicationTermination()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(backend.isRecording)
        let snapshot = try await RecordingStore(rootURL: env.libraryURL).loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 1)
        XCTAssertEqual(snapshot.recordings.first?.sources, [.microphone])
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    @MainActor
    func testTerminationAlsoFinalizesPausedRecording() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        let controller = makeController(env: env, backend: backend)

        await controller.start()
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(controller.requiresTerminationFinalization)

        await controller.prepareForApplicationTermination()

        XCTAssertEqual(controller.phase, .idle)
        let snapshot = try await RecordingStore(rootURL: env.libraryURL).loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 1)
    }

    @MainActor
    func testPendingPermissionDoesNotBlockApplicationTermination() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let permission = SuspendingMicrophonePermissionAuthorizer()
        let backend = IncrementalTestCaptureBackend()
        let controller = MicrophoneRecordingController(
            store: env.recordingStore,
            stagingStore: env.stagingStore,
            permissionAuthorizer: permission,
            backend: backend
        )

        let startTask = Task { @MainActor in
            await controller.start()
        }

        for _ in 0..<100 where controller.phase != .requestingPermission {
            await Task.yield()
        }

        XCTAssertEqual(controller.phase, .requestingPermission)
        XCTAssertFalse(controller.requiresTerminationFinalization)
        XCTAssertEqual(backend.startCount, 0)

        permission.resolve(.denied)
        await startTask.value

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.requiresTerminationFinalization)
        XCTAssertEqual(backend.startCount, 0)
    }

    @MainActor
    private func makeController(
        env: TestEnvironment,
        backend: IncrementalTestCaptureBackend
    ) -> MicrophoneRecordingController {
        MicrophoneRecordingController(
            store: env.recordingStore,
            stagingStore: env.stagingStore,
            permissionAuthorizer: TestMicrophonePermissionAuthorizer(status: .authorized),
            backend: backend
        )
    }

    private func makeEnvironment() -> TestEnvironment {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoMicrophoneControllerTests-\(UUID().uuidString)", isDirectory: true)
        let libraryURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        let stagingURL = baseURL.appendingPathComponent("Staging", isDirectory: true)
        return TestEnvironment(
            baseURL: baseURL,
            libraryURL: libraryURL,
            stagingURL: stagingURL,
            recordingStore: RecordingStore(rootURL: libraryURL),
            stagingStore: MicrophoneCaptureStagingStore(rootURL: stagingURL)
        )
    }
}

private struct TestEnvironment {
    let baseURL: URL
    let libraryURL: URL
    let stagingURL: URL
    let recordingStore: RecordingStore
    let stagingStore: MicrophoneCaptureStagingStore
}
