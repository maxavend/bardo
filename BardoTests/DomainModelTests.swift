import Foundation
import XCTest
@testable import Bardo

final class DomainModelTests: XCTestCase {
    func testRecordingRoundTripsThroughCodable() throws {
        let recording = Recording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 125.5,
            sources: [.systemAudio, .microphone],
            processingState: .processing
        )

        let data = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(Recording.self, from: data)

        XCTAssertEqual(decoded, recording)
    }

    func testTranscriptRoundTripsThroughCodable() throws {
        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let speaker = Speaker(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Maxi"
        )
        let segment = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            startTime: 3.25,
            endTime: 7.5,
            speakerID: speaker.id,
            text: "Hola, esto es Bardo."
        )
        let transcript = Transcript(
            recordingID: recordingID,
            languageCode: "es",
            speakers: [speaker],
            segments: [segment],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.0.0",
                modelID: "fixture",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                processingDuration: 12.75
            )
        )

        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)

        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(decoded.metadata.processingDuration, 12.75)
    }

    func testLegacyTranscriptMetadataWithoutProcessingDurationStillDecodes() throws {
        let json = """
        {
          "engine": "WhisperKit",
          "engineVersion": "1.0.0",
          "modelID": "fixture",
          "createdAt": 721692800
        }
        """

        let decoded = try JSONDecoder().decode(TranscriptMetadata.self, from: Data(json.utf8))
        XCTAssertNil(decoded.processingDuration)
    }
}
