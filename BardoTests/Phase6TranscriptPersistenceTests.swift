import Foundation
import XCTest
@testable import Bardo

final class Phase6TranscriptPersistenceTests: XCTestCase {
    func testDiarizationMetadataAndSpeakerAssignmentsRoundTripInTranscriptSchemaV1() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase6Transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let speaker = Speaker(name: nil)
        let recording = Recording(title: "Diarized", sources: [.importedFile])
        try await RecordingStore(rootURL: root).save(recording)

        let transcript = Transcript(
            recordingID: recording.id,
            languageCode: "en",
            speakers: [speaker],
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 1,
                    speakerID: speaker.id,
                    text: "Hello world."
                )
            ],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.0.0",
                modelID: "large-v3",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            diarizationMetadata: DiarizationMetadata(
                engine: "SpeakerKit",
                engineVersion: "1.0.0",
                modelID: "pyannote-v3",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        )

        let store = TranscriptStore(rootURL: root)
        try await store.save(transcript)
        let loaded = try await TranscriptStore(rootURL: root).read(recordingID: recording.id)

        XCTAssertEqual(loaded, transcript)

        let url = root
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(TranscriptStore.transcriptFileName)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, TranscriptDocumentV1.schemaVersion)
    }

    func testPhase5StyleTranscriptWithoutDiarizationMetadataRemainsReadable() throws {
        let recordingID = UUID()
        let json = """
        {
          "schemaVersion" : 1,
          "transcript" : {
            "languageCode" : "en",
            "metadata" : {
              "createdAt" : 721692800,
              "engine" : "WhisperKit",
              "engineVersion" : "1.0.0",
              "modelID" : "fixture"
            },
            "recordingID" : "\(recordingID.uuidString)",
            "segments" : [],
            "speakers" : []
          }
        }
        """

        let decoded = try JSONDecoder().decode(TranscriptDocumentV1.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transcript.recordingID, recordingID)
        XCTAssertNil(decoded.transcript.diarizationMetadata)
        XCTAssertTrue(decoded.transcript.speakers.isEmpty)
    }
}
