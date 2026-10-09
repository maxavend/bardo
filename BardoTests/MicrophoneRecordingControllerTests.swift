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

        backend.currentTime = 3_600.75
        controller.refreshElapsedTime()
        XCTAssertEqual(controller.elapsedTime, 3_600.75, accuracy: 0.0001)

        let stoppedRecording = await controller.stop()
        let recording = try XCTUnwrap(stoppedRecording)
        let asset = try XCTUnwrap(recording.audioAssets.first)
        XCTAssertEqual(recording.sources, [.microphone])
        XCTAssertEqual(asset.fileExtension, "m4a", "Lossless staging audio is compressed on stop")
        XCTAssertEqual(asset.metadata.codec, "AAC")
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
    func testUnexpectedInterruptionPublishesTheAudioCapturedSoFar() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        let controller = makeController(env: env, backend: backend)
        var published: [Recording] = []
        controller.onRecordingPublished = { published.append($0) }

        await controller.start(title: "Entrevista")
        backend.simulateInterruption("Input disconnected")
        await waitUntil { controller.phase != .finalizing }

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.errorMessage?.contains("Input disconnected") == true)
        let library = try await env.recordingStore.loadLibrary()
        XCTAssertEqual(library.recordings.count, 1)
        XCTAssertEqual(library.recordings.first?.title, "Entrevista")
        XCTAssertEqual(published.map(\.id), library.recordings.map(\.id))
        let remainingIssues = await MicrophoneCaptureStagingStore(rootURL: env.stagingURL).recoveryIssues()
        XCTAssertTrue(remainingIssues.isEmpty)
    }

    @MainActor
    func testTranscodingFailureKeepsLosslessStagingAudio() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        let controller = MicrophoneRecordingController(
            store: env.recordingStore,
            stagingStore: env.stagingStore,
            permissionAuthorizer: TestMicrophonePermissionAuthorizer(status: .authorized),
            backend: backend,
            transcoder: FailingAudioTranscoder()
        )

        await controller.start()
        let recordingResult = await controller.stop()

        let recording = try XCTUnwrap(recordingResult)

        let asset = try XCTUnwrap(recording.audioAssets.first)
        XCTAssertEqual(asset.fileExtension, "wav")
        let managedURL = try await env.recordingStore.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
        XCTAssertGreaterThan(try AudioMetadataReader().read(from: managedURL).duration, 0)
    }

    @MainActor
    func testCaptureWithoutAudioIsDiscardedInsteadOfKeptForRecovery() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        let backend = IncrementalTestCaptureBackend()
        backend.writesAudio = false
        let controller = makeController(env: env, backend: backend)

        await controller.start()
        let recording = await controller.stop()

        XCTAssertNil(recording)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(controller.recoveryIssues.isEmpty)
        let library = try await env.recordingStore.loadLibrary()
        XCTAssertTrue(library.recordings.isEmpty)

        controller.clearError()
        await controller.start()
        XCTAssertEqual(controller.phase, .recording, "The capture lease must be released")
        _ = await controller.stop()
    }

    @MainActor
    func testCaptureLeftBehindByACrashCanBeRecoveredWithItsTitle() async throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.baseURL) }
        // The crashed process prepared a capture and wrote crash-safe PCM into it.
        let crashedStaging = MicrophoneCaptureStagingStore(rootURL: env.stagingURL)
        let stagedURL = try await crashedStaging.prepareCapture(
            recordingID: UUID(),
            audioAssetID: UUID(),
            fileExtension: "caf",
            title: "Reunión de diseño"
        )
        try AudioTestFixture.makeWAV(at: stagedURL, duration: 1)

        // A new process sees the staging directory without an active capture.
        let relaunched = MicrophoneRecordingController(
            store: RecordingStore(rootURL: env.libraryURL),
            stagingStore: MicrophoneCaptureStagingStore(rootURL: env.stagingURL),
            permissionAuthorizer: TestMicrophonePermissionAuthorizer(status: .authorized),
            backend: IncrementalTestCaptureBackend()
        )
        await relaunched.refreshRecoveryIssues()
        let issue = try XCTUnwrap(relaunched.recoveryIssues.first)
        XCTAssertEqual(relaunched.recoveryIssues.count, 1)
        XCTAssertEqual(issue.entryName, "Reunión de diseño")

        let recoveredResult = await relaunched.recoverRecoveryIssue(issue)


        let recovered = try XCTUnwrap(recoveredResult)
        XCTAssertEqual(recovered.title, "Reunión de diseño")
        XCTAssertEqual(recovered.sources, [.microphone])
        XCTAssertTrue(relaunched.recoveryIssues.isEmpty)
        let library = try await RecordingStore(rootURL: env.libraryURL).loadLibrary()
        XCTAssertEqual(library.recordings.map(\.id), [recovered.id])
        XCTAssertTrue(library.issues.isEmpty)
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
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous state.", file: file, line: line)
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
