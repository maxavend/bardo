import Foundation
import XCTest
@testable import Bardo

final class AudioImportTests: XCTestCase {
    private var rootURL: URL!
    private var externalURL: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoAudioImportTests-\(UUID().uuidString)", isDirectory: true)
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

    func testSupportedFormatsAreExplicit() {
        XCTAssertEqual(
            AudioImportService.supportedFileExtensions,
            Set(["m4a", "mp3", "wav", "flac", "aac", "aiff"])
        )
    }

    func testValidWAVImportsIntoManagedStorageAndSurvivesOriginalDeletion() async throws {
        let sourceURL = externalURL.appendingPathComponent("Meeting.wav")
        try AudioTestFixture.makeWAV(at: sourceURL, sampleRate: 8_000, channelCount: 1, duration: 0.5)

        let store = RecordingStore(rootURL: rootURL)
        let importer = AudioImportService(store: store)
        let recording = try await importer.importFile(at: sourceURL)
        let asset = try XCTUnwrap(recording.audioAssets.first)

        XCTAssertEqual(recording.title, "Meeting")
        XCTAssertEqual(recording.sources, [.importedFile])
        XCTAssertEqual(asset.originalFileName, "Meeting.wav")
        XCTAssertEqual(asset.fileExtension, "wav")
        XCTAssertEqual(asset.metadata.sampleRate, 8_000, accuracy: 0.1)
        XCTAssertEqual(asset.metadata.channelCount, 1)
        XCTAssertEqual(asset.metadata.duration, 0.5, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(recording.duration), asset.metadata.duration, accuracy: 0.0001)

        let managedURL = try await store.managedAudioURL(
            recordingID: recording.id,
            audioAssetID: asset.id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
        XCTAssertEqual(try Data(contentsOf: managedURL), try Data(contentsOf: sourceURL))

        let manifestURL = rootURL
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(RecordingStore.manifestFileName)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, RecordingManifestV2.currentSchemaVersion)

        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))

        let restartedStore = RecordingStore(rootURL: rootURL)
        let restartedRecording = try await restartedStore.read(id: recording.id)
        let restartedAsset = try XCTUnwrap(restartedRecording.audioAssets.first)
        let restartedManagedURL = try await restartedStore.managedAudioURL(
            recordingID: restartedRecording.id,
            audioAssetID: restartedAsset.id
        )

        XCTAssertRecordingPersistenceEqual(restartedRecording, recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restartedManagedURL.path))
    }

    func testUnsupportedExtensionProducesControlledErrorWithoutMutation() async throws {
        let sourceURL = externalURL.appendingPathComponent("Meeting.ogg")
        try Data("not important".utf8).write(to: sourceURL)
        let store = RecordingStore(rootURL: rootURL)
        let importer = AudioImportService(store: store)

        do {
            _ = try await importer.importFile(at: sourceURL)
            XCTFail("Expected unsupported extension to fail")
        } catch AudioImportError.unsupportedFileExtension(let value) {
            XCTAssertEqual(value, "ogg")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        let snapshot = try await store.loadLibrary()
        XCTAssertTrue(snapshot.recordings.isEmpty)
    }

    func testSupportedExtensionWithInvalidContentsFailsBeforeLibraryMutation() async throws {
        let sourceURL = externalURL.appendingPathComponent("Fake.mp3")
        try Data("definitely not audio".utf8).write(to: sourceURL)
        let store = RecordingStore(rootURL: rootURL)
        let importer = AudioImportService(store: store)

        do {
            _ = try await importer.importFile(at: sourceURL)
            XCTFail("Expected invalid audio to fail")
        } catch AudioImportError.invalidAudio(_) {
            // Expected: AVAudioFile rejected the contents before store mutation.
        }

        let snapshot = try await store.loadLibrary()
        XCTAssertTrue(snapshot.recordings.isEmpty)
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testCopyFailureDoesNotLeaveAValidRecording() async throws {
        let missingSource = externalURL.appendingPathComponent("Missing.wav")
        let asset = AudioAsset(
            originalFileName: "Missing.wav",
            fileExtension: "wav",
            metadata: AudioMetadata(
                duration: 1,
                codec: "Linear PCM",
                sampleRate: 8_000,
                channelCount: 1
            )
        )
        let recording = Recording(
            title: "Missing",
            duration: 1,
            sources: [.importedFile],
            audioAssets: [asset]
        )
        let store = RecordingStore(rootURL: rootURL)

        do {
            try await store.importRecording(recording, audioAsset: asset, from: missingSource)
            XCTFail("Expected the managed copy to fail")
        } catch RecordingStoreError.fileSystem(_, _, _) {
            // Expected.
        }

        let recordingDirectory = rootURL.appendingPathComponent(recording.id.uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingDirectory.path))
        let snapshot = try await store.loadLibrary()
        XCTAssertTrue(snapshot.recordings.isEmpty)
    }

    func testV1ManifestRemainsReadableWithoutAudioAssets() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let directory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id.uuidString)",
          "title": "Legacy",
          "createdAtEpochSeconds": 1700000000,
          "duration": 12.5,
          "sources": ["importedFile"],
          "processingState": "pending"
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent(RecordingStore.manifestFileName))

        let recording = try await RecordingStore(rootURL: rootURL).read(id: id)

        XCTAssertEqual(recording.id, id)
        XCTAssertEqual(recording.title, "Legacy")
        XCTAssertEqual(recording.duration, 12.5)
        XCTAssertTrue(recording.audioAssets.isEmpty)
    }
}
