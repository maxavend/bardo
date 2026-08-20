import Foundation
import XCTest
@testable import Bardo

final class TranscriptStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testTranscriptRoundTripSurvivesFreshStoreInstance() async throws {
        let recording = Recording(title: "Transcript", sources: [.importedFile])
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(recording)

        let transcript = makeTranscript(recordingID: recording.id)
        try await TranscriptStore(rootURL: rootURL).save(transcript)

        let restartedStore = TranscriptStore(rootURL: rootURL)
        let loaded = try await restartedStore.read(recordingID: recording.id)

        XCTAssertEqual(loaded, transcript)

        let transcriptURL = rootURL
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(TranscriptStore.transcriptFileName)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: transcriptURL)) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, TranscriptDocumentV1.schemaVersion)
    }

    func testCorruptTranscriptDoesNotPreventRecordingLibraryRecovery() async throws {
        let recording = Recording(title: "Audio remains", sources: [.microphone])
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(recording)

        let transcriptURL = rootURL
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(TranscriptStore.transcriptFileName)
        try Data("{ definitely-not-json".utf8).write(to: transcriptURL)

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()
        XCTAssertEqual(snapshot.recordings.map(\.id), [recording.id])

        do {
            _ = try await TranscriptStore(rootURL: rootURL).read(recordingID: recording.id)
            XCTFail("Expected corrupt transcript to be reported")
        } catch TranscriptStoreError.invalidTranscript {
            // Expected. The Recording and its audio remain independently recoverable.
        }
    }

    func testFailedTranscriptEncodingDoesNotReplacePreviouslyValidTranscript() async throws {
        let recording = Recording(title: "Stable transcript", sources: [.importedFile])
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(recording)

        let store = TranscriptStore(rootURL: rootURL)
        let valid = makeTranscript(recordingID: recording.id)
        try await store.save(valid)

        var invalid = makeTranscript(recordingID: recording.id)
        invalid.segments[0].words[0] = TranscriptWord(
            startTime: 0,
            endTime: 0.2,
            text: "Hello",
            probability: .nan
        )

        do {
            try await store.save(invalid)
            XCTFail("Expected non-finite JSON value to fail encoding")
        } catch {
            // Expected.
        }

        let reloaded = try await TranscriptStore(rootURL: rootURL).read(recordingID: recording.id)
        XCTAssertEqual(reloaded, valid)
    }

    func testTemporaryTranscriptResidueIsPreservedAndDiscoverable() async throws {
        let recording = Recording(title: "Interrupted", sources: [.importedFile])
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(recording)

        let residue = rootURL
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(".transcript-interrupted.tmp")
        try Data("partial".utf8).write(to: residue)

        let artifacts = await TranscriptStore(rootURL: rootURL)
            .temporaryArtifacts(recordingID: recording.id)
        XCTAssertEqual(artifacts.map(\.lastPathComponent), [residue.lastPathComponent])

        let snapshot = try await RecordingStore(rootURL: rootURL).loadLibrary()
        XCTAssertEqual(snapshot.recordings.map(\.id), [recording.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: residue.path))
    }

    private func makeTranscript(recordingID: Recording.ID) -> Transcript {
        Transcript(
            recordingID: recordingID,
            languageCode: "en",
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 1,
                    text: "Hello world.",
                    words: [
                        TranscriptWord(startTime: 0, endTime: 0.4, text: "Hello", probability: 0.98),
                        TranscriptWord(startTime: 0.5, endTime: 1, text: "world.", probability: 0.95)
                    ]
                )
            ],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.0.0",
                modelID: "test-model",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }
}
