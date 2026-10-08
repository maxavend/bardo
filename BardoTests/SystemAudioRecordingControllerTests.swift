import Foundation
import XCTest
@testable import Bardo

final class SystemAudioRecordingControllerTests: XCTestCase {
    private var baseURL: URL!
    private var libraryURL: URL!
    private var stagingURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSystemAudioController-\(UUID().uuidString)", isDirectory: true)
        libraryURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        stagingURL = baseURL.appendingPathComponent("SystemStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseURL {
            try? FileManager.default.removeItem(at: baseURL)
        }
        baseURL = nil
        libraryURL = nil
        stagingURL = nil
    }

    @MainActor
    func testPickerCancellationCreatesNoRecordingAndReleasesLease() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: false)
        XCTAssertEqual(controller.phase, .selectingContent)
        XCTAssertEqual(picker.presentCount, 1)
        XCTAssertEqual(backend.startCount, 0)

        picker.cancelInitial()
        await waitUntil { controller.phase == .idle }

        XCTAssertEqual(backend.startCount, 0)
        let snapshot = try await store.loadLibrary()
        XCTAssertTrue(snapshot.recordings.isEmpty)

        let micBackend = IncrementalTestCaptureBackend()
        let mic = MicrophoneRecordingController(
            store: store,
            stagingStore: MicrophoneCaptureStagingStore(rootURL: baseURL.appendingPathComponent("MicStaging")),
            permissionAuthorizer: TestMicrophonePermissionAuthorizer(status: .authorized),
            backend: micBackend
        )
        await mic.start()
        XCTAssertTrue(mic.isRecording)
        _ = await mic.stop()
    }

    @MainActor
    func testSystemOnlyWritesBeforeStopPublishesAndSurvivesRestartPlayback() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        backend.currentTime = 3_600.75
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: false)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }

        let stagingSystemURL = try XCTUnwrap(backend.lastSystemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingSystemURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: stagingSystemURL).count, 0)
        controller.refreshElapsedTime()
        XCTAssertEqual(controller.elapsedTime, 3_600.75, accuracy: 0.001)

        let stopped = await controller.stop()
        let recording = try XCTUnwrap(stopped)
        XCTAssertEqual(recording.sources, [.systemAudio])
        XCTAssertEqual(recording.audioAssets.map(\.role), [.systemOriginal])
        XCTAssertEqual(recording.audioAssets.first?.timelineOffset, 0)

        let restartedStore = RecordingStore(rootURL: libraryURL)
        let model = LibraryViewModel(store: restartedStore)
        await model.reload()

        XCTAssertEqual(model.recordings.first?.id, recording.id)
        XCTAssertTrue(model.playback.isLoaded)
        XCTAssertTrue(model.issues.isEmpty)
        let restartedRecording = try await restartedStore.read(id: recording.id)
        XCTAssertRecordingPersistenceEqual(restartedRecording, recording)
    }

    @MainActor
    func testDualCaptureKeepsIndependentSourcesUsesSharedPTSAndCreatesDerivedMix() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        backend.systemFirstPTS = 500
        backend.microphoneFirstPTS = 500.075
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(
            store: store,
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )

        await controller.start(includeMicrophone: true)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        XCTAssertTrue(backend.lastIncludeMicrophone)
        let systemStagingURL = try XCTUnwrap(backend.lastSystemURL)
        let microphoneStagingURL = try XCTUnwrap(backend.lastMicrophoneURL)
        XCTAssertGreaterThan(try Data(contentsOf: systemStagingURL).count, 0)
        XCTAssertGreaterThan(try Data(contentsOf: microphoneStagingURL).count, 0)

        let stopped = await controller.stop()
        let recording = try XCTUnwrap(stopped)
        XCTAssertEqual(recording.sources, [.systemAudio, .microphone])
        XCTAssertEqual(recording.audioAssets.count, 3)

        let system = try XCTUnwrap(recording.audioAssets.first { $0.role == .systemOriginal })
        let mic = try XCTUnwrap(recording.audioAssets.first { $0.role == .microphoneOriginal })
        let mix = try XCTUnwrap(recording.audioAssets.first { $0.role == .conversationMix })
        XCTAssertEqual(system.timelineOffset, 0, accuracy: 0.0001)
        XCTAssertEqual(mic.timelineOffset, 0.075, accuracy: 0.0001)
        XCTAssertEqual(Set(mix.derivedFromAssetIDs), Set([system.id, mic.id]))
        XCTAssertTrue(mix.role.isDerived)

        let restartedStore = RecordingStore(rootURL: libraryURL)
        let restarted = try await restartedStore.read(id: recording.id)
        XCTAssertRecordingPersistenceEqual(restarted, recording)
        for asset in restarted.audioAssets {
            let url = try await restartedStore.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }

        let model = LibraryViewModel(store: restartedStore)
        await model.reload()
        XCTAssertTrue(model.playback.isLoaded)
        XCTAssertEqual(model.recordings.first?.playbackAudioAssets.first?.role, .conversationMix)
    }

    @MainActor
    func testMissingDerivedMixFallsBackToOriginalPlayback() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(
            store: store,
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )

        await controller.start(includeMicrophone: true)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        let stopped = await controller.stop()
        let recording = try XCTUnwrap(stopped)
        let mix = try XCTUnwrap(recording.audioAssets.first { $0.role == .conversationMix })
        let system = try XCTUnwrap(recording.audioAssets.first { $0.role == .systemOriginal })
        let mic = try XCTUnwrap(recording.audioAssets.first { $0.role == .microphoneOriginal })
        let mixURL = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: mix.id)
        try FileManager.default.removeItem(at: mixURL)

        let restartedStore = RecordingStore(rootURL: libraryURL)
        let model = LibraryViewModel(store: restartedStore)
        await model.reload()

        XCTAssertTrue(model.playback.isLoaded)
        XCTAssertTrue(model.issues.contains { $0.kind == .missingDerivedAudioFile })
        let systemURL = try await restartedStore.managedAudioURL(recordingID: recording.id, audioAssetID: system.id)
        let micURL = try await restartedStore.managedAudioURL(recordingID: recording.id, audioAssetID: mic.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    @MainActor
    func testCorruptDerivedMixFallsBackToOriginalPlayback() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(
            store: store,
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )

        await controller.start(includeMicrophone: true)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        let stopped = await controller.stop()
        let recording = try XCTUnwrap(stopped)
        let mix = try XCTUnwrap(recording.audioAssets.first { $0.role == .conversationMix })
        let system = try XCTUnwrap(recording.audioAssets.first { $0.role == .systemOriginal })
        let mic = try XCTUnwrap(recording.audioAssets.first { $0.role == .microphoneOriginal })
        let mixURL = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: mix.id)
        try Data("corrupt derived mix".utf8).write(to: mixURL)

        let restartedStore = RecordingStore(rootURL: libraryURL)
        let model = LibraryViewModel(store: restartedStore)
        await model.reload()

        XCTAssertTrue(model.playback.isLoaded)
        let systemURL = try await restartedStore.managedAudioURL(recordingID: recording.id, audioAssetID: system.id)
        let micURL = try await restartedStore.managedAudioURL(recordingID: recording.id, audioAssetID: mic.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    @MainActor
    func testMicrophoneFailurePublishesGoodSystemSourceAndPreservesStagingEvidence() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        backend.microphoneError = "Input route disappeared"
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(
            store: store,
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )

        await controller.start(includeMicrophone: true)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        let stopped = await controller.stop()
        let recording = try XCTUnwrap(stopped)

        XCTAssertEqual(recording.sources, [.systemAudio])
        XCTAssertEqual(recording.audioAssets.map(\.role), [.systemOriginal])
        XCTAssertFalse(controller.recoveryIssues.isEmpty)
        XCTAssertTrue(controller.errorMessage?.contains("Input route disappeared") == true)
        let snapshot = try await store.loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 1)
    }

    @MainActor
    func testMixFailureDoesNotDestroyOriginals() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(
            store: store,
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized),
            mixer: FailingConversationMixer(message: "Synthetic mix failure")
        )

        await controller.start(includeMicrophone: true)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        let stopped = await controller.stop()
        let recording = try XCTUnwrap(stopped)

        XCTAssertEqual(Set(recording.audioAssets.map(\.role)), Set([.systemOriginal, .microphoneOriginal]))
        XCTAssertTrue(controller.errorMessage?.contains("derived conversation mix") == true)
        for asset in recording.audioAssets {
            _ = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
        }
    }

    @MainActor
    func testSelectionUpdateUsesCurrentStreamAndCancelledUpdateKeepsRecording() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: false)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }

        picker.updateSelection()
        await waitUntil { backend.updateCount == 1 && controller.phase == .recording }
        picker.cancelUpdate()
        await Task.yield()

        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(backend.startCount, 1)
        _ = await controller.stop()
    }

    @MainActor
    func testSystemSelectionOwnsSameProcessLeaseAsPhase3Microphone() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let system = makeController(store: store, picker: picker, backend: backend)

        await system.start(includeMicrophone: false)
        XCTAssertEqual(system.phase, .selectingContent)

        let micBackend = IncrementalTestCaptureBackend()
        let mic = MicrophoneRecordingController(
            store: store,
            stagingStore: MicrophoneCaptureStagingStore(rootURL: baseURL.appendingPathComponent("MicStaging")),
            permissionAuthorizer: TestMicrophonePermissionAuthorizer(status: .authorized),
            backend: micBackend
        )
        await mic.start()

        XCTAssertFalse(mic.isRecording)
        XCTAssertEqual(micBackend.startCount, 0)
        XCTAssertEqual(mic.errorMessage, "Another Bardo recording is already active.")

        picker.cancelInitial()
        await waitUntil { system.phase == .idle }
    }

    @MainActor
    func testNormalApplicationTerminationFinalizesActiveSystemRecording() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: false)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        XCTAssertTrue(controller.requiresTerminationFinalization)

        await controller.prepareForApplicationTermination()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.requiresTerminationFinalization)
        let snapshot = try await store.loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 1)
        XCTAssertEqual(snapshot.recordings.first?.sources, [.systemAudio])
    }

    @MainActor
    func testStopDuringSelectionChangeDoesNotResurrectTheRecording() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        backend.suspendsUpdates = true
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: false)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }

        controller.changeSelection()
        picker.updateSelection()
        await waitUntil { backend.hasSuspendedUpdate }
        XCTAssertEqual(controller.phase, .changingSelection)

        let stopped = await controller.stop()
        XCTAssertNotNil(stopped)
        XCTAssertEqual(controller.phase, .idle)

        backend.resumeSuspendedUpdate()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(controller.phase, .idle, "A late selection update must not reopen a finished capture")
        XCTAssertFalse(controller.requiresTerminationFinalization)
        let second = await controller.stop()
        XCTAssertNil(second)
        XCTAssertEqual(backend.stopCount, 1)
    }

    @MainActor
    func testCancellingContentSelectionReleasesTheCaptureLease() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: false)
        XCTAssertEqual(controller.phase, .selectingContent)
        controller.cancelContentSelection()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(picker.deactivateCount, 1)
        await controller.start(includeMicrophone: false)
        XCTAssertEqual(controller.phase, .selectingContent)
        controller.cancelContentSelection()
    }

    @MainActor
    func testTitleTrackWarningsAndPublicationCallback() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        backend.systemWarning = "The system track skipped 3 short audio buffers while the Mac was busy."
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)
        var published: [Recording.ID] = []
        controller.onRecordingPublished = { published.append($0.id) }

        await controller.start(includeMicrophone: false, title: "Clase de historia")
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        backend.failTrack("Microphone stopped recording: device removed")
        await waitUntil { controller.captureWarning != nil }
        XCTAssertEqual(controller.phase, .recording)

        let recordingResult = await controller.stop()


        let recording = try XCTUnwrap(recordingResult)
        XCTAssertEqual(recording.title, "Clase de historia")
        XCTAssertEqual(published, [recording.id])
        XCTAssertTrue(controller.errorMessage?.contains("skipped 3 short audio buffers") == true)
        XCTAssertNil(controller.captureWarning)
    }

    @MainActor
    func testDualCaptureLeftBehindByACrashIsRecoveredWithBothSourcesAndMix() async throws {
        let crashedStaging = SystemAudioCaptureStagingStore(rootURL: stagingURL)
        let prepared = try await crashedStaging.prepareCapture(
            recordingID: UUID(),
            systemAssetID: UUID(),
            microphoneAssetID: UUID(),
            mixAssetID: UUID(),
            title: "Llamada con cliente"
        )
        try AudioTestFixture.makeM4A(at: prepared.systemURL, channelCount: 2, duration: 0.6)
        try AudioTestFixture.makeM4A(at: try XCTUnwrap(prepared.microphoneURL), channelCount: 1, duration: 0.5)

        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(
            store: store,
            picker: FakeSystemContentPicker(),
            backend: FakeSystemAudioCaptureBackend()
        )
        await controller.refreshRecoveryIssues()
        let issue = try XCTUnwrap(controller.recoveryIssues.first)
        XCTAssertEqual(issue.entryName, "Llamada con cliente")

        let recoveredResult = await controller.recoverRecoveryIssue(issue)


        let recovered = try XCTUnwrap(recoveredResult)
        XCTAssertEqual(recovered.title, "Llamada con cliente")
        XCTAssertEqual(recovered.sources, [.systemAudio, .microphone])
        XCTAssertEqual(Set(recovered.audioAssets.map(\.role)), [.systemOriginal, .microphoneOriginal, .conversationMix])
        XCTAssertTrue(controller.recoveryIssues.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directoryURL.path))

        let model = LibraryViewModel(store: RecordingStore(rootURL: libraryURL))
        await model.reload()
        XCTAssertEqual(model.recordings.map(\.id), [recovered.id])
        XCTAssertTrue(model.playback.isLoaded)
    }

    @MainActor
    func testUnreadableCaptureCannotBeRecoveredButStaysAvailableForReview() async throws {
        let crashedStaging = SystemAudioCaptureStagingStore(rootURL: stagingURL)
        let prepared = try await crashedStaging.prepareCapture(
            recordingID: UUID(),
            systemAssetID: UUID(),
            microphoneAssetID: nil,
            mixAssetID: nil
        )
        try Data("index-less audio from an old Bardo build".utf8).write(to: prepared.systemURL)

        let controller = makeController(
            store: RecordingStore(rootURL: libraryURL),
            picker: FakeSystemContentPicker(),
            backend: FakeSystemAudioCaptureBackend()
        )
        await controller.refreshRecoveryIssues()
        let issue = try XCTUnwrap(controller.recoveryIssues.first)

        let recovered = await controller.recoverRecoveryIssue(issue)
        XCTAssertNil(recovered)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.recoveryIssues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.systemURL.path))
    }

    @MainActor
    private func makeController(
        store: RecordingStore,
        picker: FakeSystemContentPicker,
        backend: FakeSystemAudioCaptureBackend,
        microphonePermission: any MicrophonePermissionAuthorizing = TestMicrophonePermissionAuthorizer(status: .authorized),
        mixer: any ConversationMixing = AVFoundationConversationMixer()
    ) -> SystemAudioRecordingController {
        SystemAudioRecordingController(
            store: store,
            stagingStore: SystemAudioCaptureStagingStore(rootURL: stagingURL),
            picker: picker,
            backend: backend,
            microphonePermission: microphonePermission,
            mixer: mixer
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for asynchronous state.", file: file, line: line)
    }
}
