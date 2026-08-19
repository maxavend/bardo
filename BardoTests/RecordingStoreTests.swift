import Foundation
import XCTest
@testable import Bardo

final class RecordingStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testSaveAndReadPreserveRecordingAndCurrentSchemaVersion() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let recording = makeRecording(
            id: id,
            title: "Persisted sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123_456)
        )
        let store = RecordingStore(rootURL: rootURL)

        try await store.save(recording)
        let loaded = try await store.read(id: id)

        XCTAssertEqual(loaded, recording)

        let manifestURL = rootURL
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(RecordingStore.manifestFileName)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, RecordingManifestV3.currentSchemaVersion)
    }

    func testCurrentSchemaPreservesArbitraryCreatedAtExactly() async throws {
        let recording = makeRecording(
            id: UUID(),
            title: "Arbitrary timestamp",
            createdAt: Date()
        )
        let store = RecordingStore(rootURL: rootURL)

        try await store.save(recording)
        let loaded = try await RecordingStore(rootURL: rootURL).read(id: recording.id)

        XCTAssertEqual(
            loaded.createdAt.timeIntervalSince1970.bitPattern,
            recording.createdAt.timeIntervalSince1970.bitPattern
        )
        XCTAssertRecordingPersistenceEqual(loaded, recording)
    }

    func testMultipleRecordingsCoexistAndFreshStoreRebuildsFromDisk() async throws {
        let first = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            title: "Older",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
            title: "Newer",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let firstStore = RecordingStore(rootURL: rootURL)

        try await firstStore.save(first)
        try await firstStore.save(second)

        let restartedStore = RecordingStore(rootURL: rootURL)
        let snapshot = try await restartedStore.loadLibrary()

        XCTAssertEqual(snapshot.recordings, [second, first])
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testUpdateAndDeleteHaveExplicitSemantics() async throws {
        var recording = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000121")!,
            title: "Original"
        )
        let store = RecordingStore(rootURL: rootURL)

        try await store.save(recording)
        recording.title = "Updated"
        recording.processingState = .completed
        try await store.update(recording)

        let updated = try await store.read(id: recording.id)
        XCTAssertEqual(updated, recording)

        try await store.delete(id: recording.id)
        do {
            _ = try await store.read(id: recording.id)
            XCTFail("Expected the deleted recording to be unavailable")
        } catch RecordingStoreError.recordingNotFound(let id) {
            XCTAssertEqual(id, recording.id)
        }
    }

    func testEncodingFailureDoesNotReplacePreviouslyValidManifest() async throws {
        var recording = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000131")!,
            title: "Stable",
            duration: 42
        )
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(recording)

        recording.title = "Should not persist"
        recording.duration = .nan

        do {
            try await store.save(recording)
            XCTFail("Expected JSON encoding of NaN to fail")
        } catch {
            // Expected: encoding fails before filesystem replacement begins.
        }

        let loaded = try await RecordingStore(rootURL: rootURL).read(id: recording.id)
        XCTAssertEqual(loaded.title, "Stable")
        XCTAssertEqual(loaded.duration, 42)
    }

    private func makeRecording(
        id: UUID,
        title: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        duration: TimeInterval? = 125.5
    ) -> Recording {
        Recording(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: duration,
            sources: [.microphone, .systemAudio],
            processingState: .pending
        )
    }
}
