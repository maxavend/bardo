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

    @MainActor
    func testRecordingWithoutManagedAudioKeepsLibraryStableAndReportsPlaybackUnavailable() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = Recording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            title: "Legacy recording",
            createdAt: Date(timeIntervalSince1970: 1_700_000_300),
            duration: 42,
            sources: [.importedFile],
            processingState: .pending,
            audioAssets: []
        )
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(recording)

        let model = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await model.reload()

        XCTAssertEqual(model.recordings, [recording])
        XCTAssertEqual(model.selection, recording.id)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.issues.isEmpty)
        XCTAssertFalse(model.playback.isLoaded)
        XCTAssertFalse(model.playback.isPlaying)
        XCTAssertNotNil(model.playback.errorMessage)
    }

    @MainActor
    func testRenameRecordingPersistsTrimmedTitle() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = Recording(
            id: UUID(),
            title: "Before",
            createdAt: Date(timeIntervalSince1970: 1_700_000_400),
            duration: 10,
            sources: [.importedFile],
            processingState: .pending,
            audioAssets: []
        )
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(recording)
        let model = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await model.reload()

        await model.renameRecording(recording.id, to: "  After  ")

        let persisted = try await store.read(id: recording.id)
        XCTAssertEqual(persisted.title, "After")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testWhitespaceOnlyRecordingTitleIsRejectedWithoutChangingTitle() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = Recording(
            id: UUID(),
            title: "Keep this title",
            createdAt: Date(timeIntervalSince1970: 1_700_000_500),
            duration: 10,
            sources: [.importedFile],
            processingState: .pending,
            audioAssets: []
        )
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(recording)
        let model = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await model.reload()

        await model.renameRecording(recording.id, to: " \n\t ")

        let persisted = try await store.read(id: recording.id)
        XCTAssertEqual(persisted.title, recording.title)
        XCTAssertEqual(model.recordingActionErrorMessage, "Recording title cannot be empty.")
    }

    @MainActor
    func testDeletingSelectedRecordingRemovesOnlyThatRecordingAndClearsSelection() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let first = Recording(
            id: UUID(),
            title: "First",
            createdAt: Date(timeIntervalSince1970: 1_700_000_600),
            duration: 10,
            sources: [.importedFile],
            processingState: .pending,
            audioAssets: []
        )
        let second = Recording(
            id: UUID(),
            title: "Second",
            createdAt: Date(timeIntervalSince1970: 1_700_000_700),
            duration: 10,
            sources: [.importedFile],
            processingState: .pending,
            audioAssets: []
        )
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(first)
        try await store.save(second)
        let model = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await model.reload()
        model.selection = first.id

        await model.deleteRecording(first.id)

        XCTAssertNil(model.recordings.first(where: { $0.id == first.id }))
        XCTAssertEqual(model.recordings.map(\.id), [second.id])
        XCTAssertNil(model.selection)
        let persistedSecond = try await store.read(id: second.id)
        XCTAssertEqual(persistedSecond.id, second.id)
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoLibraryModelTests-\(UUID().uuidString)", isDirectory: true)
    }
}
