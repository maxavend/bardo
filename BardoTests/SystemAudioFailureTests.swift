import Foundation
import XCTest
@testable import Bardo

final class SystemAudioFailureTests: XCTestCase {
    private var baseURL: URL!
    private var libraryURL: URL!
    private var stagingURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSystemAudioFailures-\(UUID().uuidString)", isDirectory: true)
        libraryURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        stagingURL = baseURL.appendingPathComponent("SystemStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseURL { try? FileManager.default.removeItem(at: baseURL) }
        baseURL = nil
        libraryURL = nil
        stagingURL = nil
    }

    @MainActor
    func testSystemFailurePreservesAndPublishesGoodMicrophoneSource() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        backend.systemError = "System source disappeared"
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: true)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        let stopped = await controller.stop()
        let recording = try XCTUnwrap(stopped)

        XCTAssertEqual(recording.sources, [.microphone])
        XCTAssertEqual(recording.audioAssets.map(\.role), [.microphoneOriginal])
        XCTAssertTrue(controller.errorMessage?.contains("System source disappeared") == true)
        XCTAssertFalse(controller.recoveryIssues.isEmpty)
        let snapshot = try await store.loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 1)
        let microphone = try XCTUnwrap(recording.audioAssets.first)
        let managedURL = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: microphone.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
    }

    @MainActor
    func testStreamTerminationFinalizesAvailableSystemAudio() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: false)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        backend.interrupt("Selection became unavailable")
        await waitUntil { controller.phase == .idle || controller.phase == .failed }

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(controller.errorMessage?.contains("Selection became unavailable") == true)
        let snapshot = try await store.loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 1)
        let recording = try XCTUnwrap(snapshot.recordings.first)
        XCTAssertEqual(recording.sources, [.systemAudio])
        let asset = try XCTUnwrap(recording.audioAssets.first)
        let managedURL = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
    }

    @MainActor
    func testInitialPickerFailureCreatesNothingAndReleasesLease() async throws {
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: libraryURL)
        let controller = makeController(store: store, picker: picker, backend: backend)

        await controller.start(includeMicrophone: false)
        XCTAssertEqual(controller.phase, .selectingContent)
        picker.fail("Picker unavailable")
        await waitUntil { controller.phase == .idle }

        XCTAssertEqual(backend.startCount, 0)
        XCTAssertTrue(controller.errorMessage?.contains("Picker unavailable") == true)
        let snapshot = try await store.loadLibrary()
        XCTAssertTrue(snapshot.recordings.isEmpty)

        let micBackend = IncrementalTestCaptureBackend()
        let microphone = MicrophoneRecordingController(
            store: store,
            stagingStore: MicrophoneCaptureStagingStore(rootURL: baseURL.appendingPathComponent("MicrophoneStaging", isDirectory: true)),
            permissionAuthorizer: TestMicrophonePermissionAuthorizer(status: .authorized),
            backend: micBackend
        )
        await microphone.start()
        XCTAssertTrue(microphone.isRecording)
        XCTAssertEqual(micBackend.startCount, 1)
        _ = await microphone.stop()
    }

    @MainActor
    private func makeController(
        store: RecordingStore,
        picker: FakeSystemContentPicker,
        backend: FakeSystemAudioCaptureBackend
    ) -> SystemAudioRecordingController {
        SystemAudioRecordingController(
            store: store,
            stagingStore: SystemAudioCaptureStagingStore(rootURL: stagingURL),
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<120 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for asynchronous state.", file: file, line: line)
    }
}
