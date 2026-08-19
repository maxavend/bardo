import Foundation
import XCTest
@testable import Bardo

final class LibraryViewModelTests: XCTestCase {
    @MainActor
    func testEmptyStoreIsAValidLibraryState() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let model = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await model.reload()

        XCTAssertTrue(model.recordings.isEmpty)
        XCTAssertTrue(model.issues.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.selection)
    }

    @MainActor
    func testFreshViewModelRepresentsPersistedRecordingAfterStoreRestart() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = Recording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            title: "Persisted meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_200),
            duration: 80,
            sources: [.systemAudio],
            processingState: .pending
        )
        let firstStore = RecordingStore(rootURL: rootURL)
        try await firstStore.save(recording)

        let restartedStore = RecordingStore(rootURL: rootURL)
        let model = LibraryViewModel(store: restartedStore)
        await model.reload()

        XCTAssertEqual(model.recordings, [recording])
        XCTAssertEqual(model.selection, recording.id)
        XCTAssertEqual(model.selectedRecording, recording)
        XCTAssertNil(model.errorMessage)
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoLibraryModelTests-\(UUID().uuidString)", isDirectory: true)
    }
}
