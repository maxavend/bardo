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
    func testWholeSystemSelectionStartsRecordingWithoutAPicker() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoWholeSystem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let backend = FakeSystemAudioCaptureBackend()
        let controller = SystemAudioRecordingController(
            store: RecordingStore(rootURL: baseURL.appendingPathComponent("Library", isDirectory: true)),
            stagingStore: SystemAudioCaptureStagingStore(
                rootURL: baseURL.appendingPathComponent("SystemStaging", isDirectory: true)
            ),
            picker: WholeSystemAudioSelection(),
            backend: backend,
            microphonePermission: TestMicrophonePermissionAuthorizer(status: .authorized)
        )

        // Nothing to choose: starting goes straight to recording the whole Mac.
        await controller.start(includeMicrophone: true)
        await waitUntil { controller.phase == .recording }
        XCTAssertEqual(backend.startCount, 1)

        let recording = await controller.stop()
        XCTAssertNotNil(recording)
        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testWholeSystemSelectionReportsUpdatesOnlyWhileActive() {
        let selection = WholeSystemAudioSelection()
        var events: [Bool] = []
        selection.eventHandler = { event in
            if case .selected(let content, let isUpdate) = event {
                XCTAssertTrue(content === SystemContentSelection.entireSystem)
                events.append(isUpdate)
            }
        }

        selection.present()
        selection.present()
        selection.deactivate()
        selection.present()

        XCTAssertEqual(events, [false, true, false])
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
