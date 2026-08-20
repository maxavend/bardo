import Foundation
import XCTest
@testable import Bardo

final class Phase4PersistenceTests: XCTestCase {
    private var rootURL: URL!
    private var scratchURL: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase4Persistence-\(UUID().uuidString)", isDirectory: true)
        rootURL = base.appendingPathComponent("Library", isDirectory: true)
        scratchURL = base.appendingPathComponent("Scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
        }
        rootURL = nil
        scratchURL = nil
    }

    func testV2MicrophoneAssetRemainsReadableAndInfersOriginalRole() async throws {
        let recordingID = UUID()
        let assetID = UUID()
        let created = Date(timeIntervalSince1970: 1_700_100_000.125)
        let assetRecord = RecordingManifestV2.AudioAssetRecord(
            id: assetID,
            originalFileName: "Microphone Recording.m4a",
            fileExtension: "m4a",
            duration: 5,
            codec: "AAC",
            sampleRate: 48_000,
            channelCount: 1
        )
        let manifest = RecordingManifestV2(
            schemaVersion: 2,
            id: recordingID,
            title: "Legacy microphone",
            createdAtEpochSeconds: created.timeIntervalSince1970,
            createdAtEpochSecondsBitPattern: created.timeIntervalSince1970.bitPattern,
            duration: 5,
            sources: [.microphone],
            processingState: .pending,
            audioAssets: [assetRecord]
        )

        let directory = rootURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent(RecordingStore.manifestFileName))

        let loaded = try await RecordingStore(rootURL: rootURL).read(id: recordingID)
        XCTAssertEqual(loaded.audioAssets.count, 1)
        XCTAssertEqual(loaded.audioAssets.first?.role, .microphoneOriginal)
        XCTAssertEqual(loaded.audioAssets.first?.timelineOffset, 0)
        XCTAssertTrue(loaded.audioAssets.first?.derivedFromAssetIDs.isEmpty == true)
    }

    func testV3PublishesMultipleSourceAndDerivedAssetsAtomically() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let systemURL = scratchURL.appendingPathComponent("system.wav")
        let micURL = scratchURL.appendingPathComponent("mic.wav")
        let mixURL = scratchURL.appendingPathComponent("mix.wav")
        try AudioTestFixture.makeWAV(at: systemURL, sampleRate: 48_000, channelCount: 2, duration: 0.5)
        try AudioTestFixture.makeWAV(at: micURL, sampleRate: 48_000, channelCount: 1, duration: 0.45)
        try AudioTestFixture.makeWAV(at: mixURL, sampleRate: 48_000, channelCount: 2, duration: 0.55)

        let reader = AudioMetadataReader()
        let system = AudioAsset(
            originalFileName: "System Audio.wav",
            fileExtension: "wav",
            metadata: try reader.read(from: systemURL),
            role: .systemOriginal,
            timelineOffset: 0
        )
        let mic = AudioAsset(
            originalFileName: "Microphone.wav",
            fileExtension: "wav",
            metadata: try reader.read(from: micURL),
            role: .microphoneOriginal,
            timelineOffset: 0.05
        )
        let mix = AudioAsset(
            originalFileName: "Conversation Mix.wav",
            fileExtension: "wav",
            metadata: try reader.read(from: mixURL),
            role: .conversationMix,
            derivedFromAssetIDs: [system.id, mic.id]
        )
        let recording = Recording(
            title: "System + Microphone",
            duration: 0.55,
            sources: [.systemAudio, .microphone],
            audioAssets: [system, mic, mix]
        )

        try await store.importRecording(
            recording,
            audioFiles: [system.id: systemURL, mic.id: micURL, mix.id: mixURL]
        )

        let restarted = RecordingStore(rootURL: rootURL)
        let loaded = try await restarted.read(id: recording.id)
        XCTAssertRecordingPersistenceEqual(loaded, recording)
        XCTAssertEqual(loaded.playbackAudioAssets.first?.role, .conversationMix)

        let manifestURL = rootURL
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(RecordingStore.manifestFileName)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, 3)

        for asset in recording.audioAssets {
            let managed = try await restarted.managedAudioURL(
                recordingID: recording.id,
                audioAssetID: asset.id
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
        }
    }

    func testMissingDerivedMixIsReportedWithoutDamagingOriginals() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let systemURL = scratchURL.appendingPathComponent("source-system.wav")
        let micURL = scratchURL.appendingPathComponent("source-mic.wav")
        let mixURL = scratchURL.appendingPathComponent("source-mix.wav")
        try AudioTestFixture.makeWAV(at: systemURL, sampleRate: 48_000, channelCount: 2, duration: 0.25)
        try AudioTestFixture.makeWAV(at: micURL, sampleRate: 48_000, channelCount: 1, duration: 0.25)
        try AudioTestFixture.makeWAV(at: mixURL, sampleRate: 48_000, channelCount: 2, duration: 0.25)

        let reader = AudioMetadataReader()
        let system = AudioAsset(originalFileName: "system.wav", fileExtension: "wav", metadata: try reader.read(from: systemURL), role: .systemOriginal)
        let mic = AudioAsset(originalFileName: "mic.wav", fileExtension: "wav", metadata: try reader.read(from: micURL), role: .microphoneOriginal)
        let mix = AudioAsset(originalFileName: "mix.wav", fileExtension: "wav", metadata: try reader.read(from: mixURL), role: .conversationMix, derivedFromAssetIDs: [system.id, mic.id])
        let recording = Recording(title: "Recoverable mix", duration: 0.25, sources: [.systemAudio, .microphone], audioAssets: [system, mic, mix])

        try await store.importRecording(recording, audioFiles: [system.id: systemURL, mic.id: micURL, mix.id: mixURL])
        let managedMix = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: mix.id)
        try FileManager.default.removeItem(at: managedMix)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 1)
        XCTAssertTrue(snapshot.issues.contains { $0.kind == .missingDerivedAudioFile && $0.recordingID == recording.id })
        _ = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: system.id)
        _ = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: mic.id)
    }
}
