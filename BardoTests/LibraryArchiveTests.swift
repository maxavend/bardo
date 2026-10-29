import Foundation
import XCTest
@testable import Bardo

final class LibraryArchiveTests: XCTestCase {
    // MARK: - Persistence

    func testArchivingIsSavedInTheManifestOnlyWhenArchived() throws {
        let archived = Recording(title: "Retro", sources: [.microphone], isArchived: true)

        let manifest = RecordingManifestV3(recording: archived)
        let roundTrip = try JSONDecoder().decode(RecordingManifestV3.self, from: JSONEncoder().encode(manifest))

        XCTAssertTrue(roundTrip.recording.isArchived)
        let plain = RecordingManifestV3(recording: Recording(title: "Otra", sources: [.microphone]))
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("isArchived"), "Manifests of recordings in the Library stay as they were")
    }

    func testManifestsWrittenBeforeArchivingReadAsNotArchived() throws {
        let json = """
        {"schemaVersion":3,"id":"00000000-0000-0000-0000-000000000301","title":"Antigua",
        "createdAtEpochSeconds":1700000000,"createdAtEpochSecondsBitPattern":\(Double(1_700_000_000).bitPattern),
        "duration":12,"sources":["microphone"],"processingState":"completed","audioAssets":[]}
        """

        let manifest = try JSONDecoder().decode(RecordingManifestV3.self, from: Data(json.utf8))

        XCTAssertFalse(manifest.recording.isArchived)
        let recording = try JSONDecoder().decode(
            Recording.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000302","title":"Antigua","createdAt":0,"sources":["microphone"],"processingState":"completed"}"#.utf8)
        )
        XCTAssertFalse(recording.isArchived)
        let encoded = String(decoding: try JSONEncoder().encode(recording), as: UTF8.self)
        XCTAssertFalse(encoded.contains("isArchived"))
    }

    @MainActor
    func testArchivedStateSurvivesARestart() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let first = makeRecording("Primera", at: 100)
        let second = makeRecording("Segunda", at: 200)
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(first)
        try await store.save(second)
        let model = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await model.reload()

        await model.setArchived([first.id], true)

        XCTAssertNil(model.recordingActionErrorMessage)
        let persisted = try await RecordingStore(rootURL: rootURL).read(id: first.id)
        XCTAssertTrue(persisted.isArchived)
        let restarted = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await restarted.reload()
        XCTAssertEqual(restarted.recordings.first { $0.id == first.id }?.isArchived, true)
        XCTAssertEqual(restarted.recordings.first { $0.id == second.id }?.isArchived, false)
        XCTAssertEqual(restarted.selection, second.id, "A restart opens a conversation that is still in the Library")

        await restarted.setArchived([first.id], false)
        let restored = try await RecordingStore(rootURL: rootURL).read(id: first.id)
        XCTAssertFalse(restored.isArchived)
    }

    // MARK: - Sections

    @MainActor
    func testArchivedConversationsLeaveEveryListButArchivadas() {
        let favorites = BardoFavoritesStore(defaults: makeDefaults())
        let recorded = Recording(title: "Grabada", sources: [.microphone], isArchived: true)
        let imported = Recording(title: "Importada", sources: [.importedFile], isArchived: true)
        let active = Recording(title: "Activa", sources: [.microphone])
        favorites.set([recorded.id, active.id], favorite: true)

        for section in BardoLibrarySection.allCases where section != .archived {
            XCTAssertFalse(section.contains(recorded, favorites: favorites), "\(section)")
            XCTAssertFalse(section.contains(imported, favorites: favorites), "\(section)")
        }
        XCTAssertTrue(BardoLibrarySection.archived.contains(recorded, favorites: favorites))
        XCTAssertTrue(BardoLibrarySection.archived.contains(imported, favorites: favorites))
        XCTAssertFalse(BardoLibrarySection.archived.contains(active, favorites: favorites))
        XCTAssertTrue(BardoLibrarySection.all.contains(active, favorites: favorites))
        XCTAssertTrue(BardoLibrarySection.favorites.contains(active, favorites: favorites))
        XCTAssertTrue(favorites.contains(recorded.id), "Archiving keeps the star for when it comes back")
    }

    // MARK: - Selection and bulk actions

    @MainActor
    func testSeveralSelectedConversationsOpenNone() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let first = makeRecording("Primera", at: 100)
        let second = makeRecording("Segunda", at: 200)
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(first)
        try await store.save(second)
        let model = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await model.reload()

        model.selectedIDs = [first.id, second.id]

        XCTAssertNil(model.selection)
        XCTAssertNil(model.selectedRecording)
        await model.reload()
        XCTAssertEqual(model.selectedIDs, [first.id, second.id], "Reloading keeps the selection")

        model.selection = first.id
        XCTAssertEqual(model.selectedIDs, [first.id])
        model.selection = nil
        XCTAssertTrue(model.selectedIDs.isEmpty)
    }

    @MainActor
    func testBulkArchiveAndTrashActOnEverySelectedConversation() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let recordings = (0..<4).map { makeRecording("Conversación \($0)", at: TimeInterval($0) * 100) }
        let store = RecordingStore(rootURL: rootURL)
        for recording in recordings { try await store.save(recording) }
        let model = LibraryViewModel(store: RecordingStore(rootURL: rootURL))
        await model.reload()
        let archived: Set = [recordings[0].id, recordings[1].id, recordings[2].id]

        await model.setArchived(archived, true)

        XCTAssertEqual(Set(model.recordings.filter(\.isArchived).map(\.id)), archived)
        for id in archived {
            let persisted = try await store.read(id: id)
            XCTAssertTrue(persisted.isArchived)
        }

        model.selectedIDs = [recordings[0].id, recordings[1].id]
        await model.deleteRecordings(model.selectedIDs)

        XCTAssertEqual(Set(model.recordings.map(\.id)), [recordings[2].id, recordings[3].id])
        XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertNil(model.recordingActionErrorMessage)
        let reloaded = try await RecordingStore(rootURL: rootURL).loadLibrary()
        XCTAssertEqual(Set(reloaded.recordings.map(\.id)), [recordings[2].id, recordings[3].id])
    }

    func testArchiveTogglesToDesarchivarOnlyWhenEverySelectedOneIsArchived() {
        let archived = Recording(title: "A", sources: [.microphone], isArchived: true)
        let active = Recording(title: "B", sources: [.microphone])

        XCTAssertTrue(LibrarySelection.archives([active]))
        XCTAssertTrue(LibrarySelection.archives([archived, active]))
        XCTAssertFalse(LibrarySelection.archives([archived]))
    }

    @MainActor
    func testFavoritesForSeveralConversations() {
        let favorites = BardoFavoritesStore(defaults: makeDefaults())
        let a = UUID(), b = UUID()
        favorites.set([a], favorite: true)

        XCTAssertTrue(LibrarySelection.addsToFavorites([a, b], favorites: favorites))
        favorites.set([a, b], favorite: true)
        XCTAssertEqual(favorites.ids, [a, b])
        XCTAssertFalse(LibrarySelection.addsToFavorites([a, b], favorites: favorites))
        favorites.set([a, b], favorite: false)
        XCTAssertTrue(favorites.ids.isEmpty)
    }

    func testTheNextConversationTakesTheSelection() {
        let ids = (0..<5).map { _ in UUID() }

        XCTAssertEqual(LibrarySelection.neighbor(of: [ids[1], ids[2]], in: ids), ids[3])
        XCTAssertEqual(LibrarySelection.neighbor(of: [ids[3], ids[4]], in: ids), ids[2], "The one before, when they were last")
        XCTAssertEqual(LibrarySelection.neighbor(of: [ids[0], ids[2]], in: ids), ids[3])
        XCTAssertNil(LibrarySelection.neighbor(of: Set(ids), in: ids))
        XCTAssertNil(LibrarySelection.neighbor(of: [UUID()], in: ids))
    }

    // MARK: - Helpers

    private func makeRecording(_ title: String, at seconds: TimeInterval) -> Recording {
        Recording(
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            duration: 30,
            sources: [.microphone],
            processingState: .pending
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "BardoLibraryArchiveTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoLibraryArchiveTests-\(UUID().uuidString)", isDirectory: true)
    }
}
