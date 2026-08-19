import AVFoundation
import XCTest

@testable import Bardo

final class MicrophonePermissionTests: XCTestCase {
    @MainActor
    func testSystemAuthorizationStatesMapExplicitly() {
        XCTAssertEqual(SystemMicrophonePermissionAuthorizer.state(for: .notDetermined), .notDetermined)
        XCTAssertEqual(SystemMicrophonePermissionAuthorizer.state(for: .authorized), .authorized)
        XCTAssertEqual(SystemMicrophonePermissionAuthorizer.state(for: .denied), .denied)
        XCTAssertEqual(SystemMicrophonePermissionAuthorizer.state(for: .restricted), .restricted)
    }

    @MainActor
    func testDeniedPermissionNeverStartsCapture() async {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let permission = TestMicrophonePermissionAuthorizer(status: .denied)
        let backend = IncrementalTestCaptureBackend()
        let controller = MicrophoneRecordingController(
            store: RecordingStore(rootURL: rootURL.appendingPathComponent("Library", isDirectory: true)),
            stagingStore: MicrophoneCaptureStagingStore(rootURL: rootURL.appendingPathComponent("Staging", isDirectory: true)),
            permissionAuthorizer: permission,
            backend: backend
        )

        await controller.start()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.permissionState, .denied)
        XCTAssertEqual(permission.requestCount, 0)
        XCTAssertEqual(backend.startCount, 0)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testNotDeterminedPermissionRequestsOnceAndTransitionsToCapture() async {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let permission = TestMicrophonePermissionAuthorizer(
            status: .notDetermined,
            requestResult: .authorized
        )
        let backend = IncrementalTestCaptureBackend()
        let controller = MicrophoneRecordingController(
            store: RecordingStore(rootURL: rootURL.appendingPathComponent("Library", isDirectory: true)),
            stagingStore: MicrophoneCaptureStagingStore(rootURL: rootURL.appendingPathComponent("Staging", isDirectory: true)),
            permissionAuthorizer: permission,
            backend: backend
        )

        await controller.start()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(controller.permissionState, .authorized)
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(backend.startCount, 1)
        _ = await controller.stop()
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoMicrophonePermissionTests-\(UUID().uuidString)", isDirectory: true)
    }
}
