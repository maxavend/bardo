import Foundation
import XCTest
@testable import Bardo

final class SystemAudioSelectionTests: XCTestCase {
    @MainActor
    func testExplicitChangeSourceAppliesPickerFilterWithoutStreamAssociationAndCancelKeepsCapture() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSystemSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let picker = FakeSystemContentPicker()
        let backend = FakeSystemAudioCaptureBackend()
        let store = RecordingStore(rootURL: baseURL.appendingPathComponent("Library", isDirectory: true))
        let controller = SystemAudioRecordingController(
            store: store,
            stagingStore: SystemAudioCaptureStagingStore(
                rootURL: baseURL.appendingPathComponent("SystemStaging", isDirectory: true)
            ),
            picker: picker,
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )

        await controller.start(includeMicrophone: false)
        picker.selectInitial("first")
        await waitUntil { controller.phase == .recording }
        XCTAssertEqual(backend.startCount, 1)

        controller.changeSelection()
        XCTAssertEqual(controller.phase, .changingSelection)
        XCTAssertEqual(picker.presentCount, 2)

        // present() has no active SCStream association, so the real picker is allowed to
        // return stream == nil. Bardo must still apply the new filter to its existing stream.
        picker.selectInitial("replacement")
        await waitUntil { backend.updateCount == 1 && controller.phase == .recording }
        XCTAssertEqual(backend.startCount, 1)

        controller.changeSelection()
        XCTAssertEqual(controller.phase, .changingSelection)
        picker.cancelInitial()
        await waitUntil { controller.phase == .recording }
        XCTAssertEqual(backend.updateCount, 1)

        _ = await controller.stop()
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
