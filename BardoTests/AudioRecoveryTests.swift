import Foundation
import XCTest
@testable import Bardo

final class AudioRecoveryTests: XCTestCase {
    private var rootURL: URL!
    private var externalURL: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoAudioRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = base.appendingPathComponent("Library", isDirectory: true)
        externalURL = base.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
        }
        rootURL = nil
        externalURL = nil
    }

    func testMissingManagedAudioIsReportedWithoutHidingRecording() async throws {
        let sourceURL = externalURL.appendingPathComponent("Recoverable.wav")
        try AudioTestFixture.makeWAV(at: sourceURL)
        let store = RecordingStore(rootURL: rootURL)
        let recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        let asset = try XCTUnwrap(recording.audioAssets.first)
        let managedURL = try await store.managedAudioURL(
            recordingID: recording.id,
            audioAssetID: asset.id
        )
        try FileManager.default.removeItem(at: managedURL)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()

        XCTAssertEqual(snapshot.recordings.count, 1)
        XCTAssertRecordingPersistenceEqual(try XCTUnwrap(snapshot.recordings.first), recording)
        XCTAssertEqual(snapshot.issues.map(\.kind), [.missingAudioFile])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: rootURL
                .appendingPathComponent(recording.id.uuidString, isDirectory: true)
                .appendingPathComponent(RecordingStore.manifestFileName)
                .path
        ))
    }

    func testTemporaryAudioResidueIsDetectedAndPreserved() async throws {
        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000721")!
        let asset = AudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000722")!,
            originalFileName: "Interrupted.wav",
            fileExtension: "wav",
            metadata: AudioMetadata(duration: 1, codec: "Linear PCM", sampleRate: 8_000, channelCount: 1)
        )
        let recording = Recording(
            id: recordingID,
            title: "Interrupted",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1,
            sources: [.importedFile],
            audioAssets: [asset]
        )
        let store = RecordingStore(rootURL: rootURL)
        try await store.save(recording)

        let audioDirectory = rootURL
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
            .appendingPathComponent(RecordingStore.audioDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let tempURL = audioDirectory.appendingPathComponent(".audio-\(asset.id.uuidString).tmp")
        try Data("partial audio".utf8).write(to: tempURL)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()

        XCTAssertEqual(snapshot.recordings.count, 1)
        XCTAssertRecordingPersistenceEqual(try XCTUnwrap(snapshot.recordings.first), recording)
        XCTAssertEqual(Set(snapshot.issues.map(\.kind)), Set([.temporaryAudioArtifact, .missingAudioFile]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testCorruptManifestPreservesExistingManagedAudioEvidence() async throws {
        let sourceURL = externalURL.appendingPathComponent("Evidence.wav")
        try AudioTestFixture.makeWAV(at: sourceURL)
        let store = RecordingStore(rootURL: rootURL)
        let recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        let asset = try XCTUnwrap(recording.audioAssets.first)
        let managedURL = try await store.managedAudioURL(
            recordingID: recording.id,
            audioAssetID: asset.id
        )
        let manifestURL = rootURL
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(RecordingStore.manifestFileName)
        try Data("{ corrupt".utf8).write(to: manifestURL)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()

        XCTAssertTrue(snapshot.recordings.isEmpty)
        XCTAssertEqual(snapshot.issues.map(\.kind), [.corruptManifest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testCorruptManagedAudioLeavesLibraryStableAndPlaybackFailsControlled() async throws {
        let sourceURL = externalURL.appendingPathComponent("CorruptLater.wav")
        try AudioTestFixture.makeWAV(at: sourceURL)
        let store = RecordingStore(rootURL: rootURL)
        let recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        let asset = try XCTUnwrap(recording.audioAssets.first)
        let managedURL = try await store.managedAudioURL(
            recordingID: recording.id,
            audioAssetID: asset.id
        )
        try Data("managed audio became corrupt".utf8).write(to: managedURL)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 1)
        XCTAssertRecordingPersistenceEqual(try XCTUnwrap(snapshot.recordings.first), recording)

        let playback = await MainActor.run { AudioPlaybackController() }
        await MainActor.run {
            playback.load(url: managedURL)
            XCTAssertFalse(playback.isLoaded)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertNotNil(playback.errorMessage)
        }
    }
}
