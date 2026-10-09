import Foundation
import XCTest
@testable import Bardo

final class TranscriptionBackendTests: XCTestCase {
    func testWhisperKitIsTheOnlyBackendAndUsesTurboByDefault() {
        XCTAssertEqual(TranscriptionBackend.allCases, [.whisperKit])
        XCTAssertEqual(TranscriptionSelection(), TranscriptionSelection())
        XCTAssertEqual(TranscriptionSelection().modelID, TranscriptionModelManager.modelID)
    }

    func testLegacySelectionMetadataDecodesToTurboForCompatibility() throws {
        let json = Data("{\"backend\":\"parakeet\",\"modelID\":\"legacy\"}".utf8)
        let selection = try JSONDecoder().decode(TranscriptionSelection.self, from: json)
        XCTAssertEqual(selection, TranscriptionSelection())
    }

    func testTranscriptMetadataRoundTripsTurboSelection() throws {
        let transcript = Transcript(
            recordingID: UUID(),
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Hello")],
            metadata: TranscriptMetadata(
                engine: "WhisperKit", engineVersion: "1.1.0",
                modelID: TranscriptionModelManager.modelID, selection: TranscriptionSelection()
            )
        )
        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(decoded.metadata.selection, TranscriptionSelection())
    }
}
