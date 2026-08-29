import Foundation
import XCTest
@testable import Bardo

final class SystemAudioPauseResumeTests: XCTestCase {
    @MainActor
    func testPauseResumeAndStopFromPausedAreDeterministic() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSystemPause-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let store = RecordingStore(rootURL: baseURL.appendingPathComponent("Library"))
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let controller = SystemAudioRecordingController(
            store: store,
            stagingStore: SystemAudioCaptureStagingStore(
                rootURL: baseURL.appendingPathComponent("Staging")
            ),
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )

        await controller.start(includeMicrophone: false)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }

        await controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(backend.pauseCount, 1)

        await controller.pause()
        XCTAssertEqual(backend.pauseCount, 1, "Repeated pause must be a no-op")

        await controller.resume()
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(backend.resumeCount, 1)

        await controller.pause()
        let recording = await controller.stop()
        XCTAssertNotNil(recording)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(backend.stopCount, 1)
    }

    @MainActor
    func testPausedSystemRecordingIsFinalizedOnTermination() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSystemPauseTermination-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let store = RecordingStore(rootURL: baseURL.appendingPathComponent("Library"))
        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let controller = SystemAudioRecordingController(
            store: store,
            stagingStore: SystemAudioCaptureStagingStore(
                rootURL: baseURL.appendingPathComponent("Staging")
            ),
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )

        await controller.start(includeMicrophone: false)
        picker.selectInitial()
        await waitUntil { controller.phase == .recording }
        await controller.pause()
        XCTAssertTrue(controller.requiresTerminationFinalization)

        await controller.prepareForApplicationTermination()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.requiresTerminationFinalization)
        let library = try await store.loadLibrary()
        XCTAssertEqual(library.recordings.count, 1)
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
