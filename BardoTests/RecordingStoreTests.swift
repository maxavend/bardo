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

    func testCompressedAudioReplacesTheTrackAndItsFileUnderTheNewName() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let wav = rootURL.appendingPathComponent("original.wav")
        try AudioTestFixture.makeWAV(at: wav, sampleRate: 48_000, duration: 2)
        let original = AudioAsset(
            originalFileName: "Recording.wav",
            fileExtension: "wav",
            metadata: try AudioMetadataReader().read(from: wav),
            role: .microphoneOriginal
        )
        let recording = Recording(title: "Compress", createdAt: Date(), duration: 2, sources: [.microphone], audioAssets: [original])
        try await store.importRecording(recording, audioAsset: original, from: wav)
        let oldURL = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: original.id)

        let compact = rootURL.appendingPathComponent("compact.m4a")
        try await AudioFileTranscoder().transcode(
            from: oldURL,
            to: compact,
            encoding: AudioEncoding(preset: .compact, format: .aac)
        )
        let replacement = AudioAsset(
            id: original.id,
            originalFileName: "Recording.m4a",
            fileExtension: "m4a",
            metadata: try AudioMetadataReader().read(from: compact),
            role: .microphoneOriginal
        )

        let updated = try await store.replaceAudio(of: recording.id, with: [(replacement, compact)])

        XCTAssertEqual(updated.audioAssets, [replacement])
        let reread = try await store.read(id: recording.id)
        XCTAssertEqual(reread.audioAssets, [replacement])
        let newURL = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: original.id)
        XCTAssertEqual(newURL.pathExtension, "m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path), "The old file goes once the manifest points at the new one")
        XCTAssertEqual(try AudioMetadataReader().read(from: newURL).duration, 2, accuracy: 0.1)
    }

    func testRecordingDirectoryURLIsInsideStoreRoot() async throws {
        let recording = makeRecording(id: UUID(), title: "Managed location")
        let store = RecordingStore(rootURL: rootURL)

        try await store.save(recording)

        let directory = try await store.recordingDirectoryURL(recordingID: recording.id)

        XCTAssertEqual(directory.standardizedFileURL.deletingLastPathComponent(), rootURL.standardizedFileURL)
        XCTAssertEqual(directory.lastPathComponent, recording.id.uuidString)
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
