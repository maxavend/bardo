import Foundation
import XCTest
@testable import Bardo

final class TranscriptionBackendTests: XCTestCase {
    func testSelectionCasesIncludeParakeetAndWhisperKitPresets() {
        XCTAssertEqual(TranscriptionBackend.allCases, [.parakeet, .whisperKit])
        XCTAssertEqual(
            TranscriptionPreset.allCases,
            [.instant, .balanced, .maximumAccuracy]
        )
    }

    func testTranscriptMetadataPreservesSelectionThroughCodableRoundTrip() throws {
        let recordingID = UUID()
        let selection = TranscriptionSelection(
            preset: .balanced,
            backend: .whisperKit,
            modelID: "large-v3-v20240930_turbo_632MB"
        )
        let transcript = Transcript(
            recordingID: recordingID,
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Hello")],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.1.0",
                modelID: selection.modelID,
                selection: selection
            )
        )

        let encoded = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: encoded)

        XCTAssertEqual(decoded.metadata, transcript.metadata)
        XCTAssertEqual(decoded.metadata.selection, selection)
    }
}
