import Foundation
import XCTest
@testable import Bardo

final class TranscriptionBackendTests: XCTestCase {
    func testWhisperTurboIsTheDefaultEngine() {
        XCTAssertEqual(TranscriptionBackend.allCases, [.whisperKit, .appleSpeech])
        XCTAssertEqual(TranscriptionEngine.default, .balanced)
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

    func testEachEngineKeepsItsOwnSelection() throws {
        for selection in [
            TranscriptionSelection(modelID: TranscriptionModelManager.largeModelID),
            TranscriptionSelection(backend: .appleSpeech, modelID: TranscriptionEngine.apple.rawValue)
        ] {
            let decoded = try JSONDecoder().decode(TranscriptionSelection.self, from: JSONEncoder().encode(selection))
            XCTAssertEqual(decoded, selection)
        }
    }

    func testTranscriptKeepsTheEngineThatMadeItAndHowLongItTook() throws {
        for engine in TranscriptionEngine.allCases {
            let metadata = TranscriptMetadata(
                engine: engine == .apple ? "Apple Speech" : "WhisperKit", engineVersion: "1.1.0",
                modelID: engine.selection.modelID, selection: engine.selection, processingDuration: 84.4
            )
            let decoded = try JSONDecoder().decode(TranscriptMetadata.self, from: JSONEncoder().encode(metadata))
            XCTAssertEqual(TranscriptionEngine(metadata: decoded), engine)
            XCTAssertEqual(decoded.processingDuration, 84.4)
        }
    }

    func testTranscriptSavedBeforeTheChoiceIsKnownByItsWhisperModel() throws {
        func decode(_ modelID: String) throws -> TranscriptMetadata {
            let json = """
            {"engine":"WhisperKit","engineVersion":"1.0.0","modelID":"\(modelID)","createdAt":721692800}
            """
            return try JSONDecoder().decode(TranscriptMetadata.self, from: Data(json.utf8))
        }
        XCTAssertEqual(TranscriptionEngine(metadata: try decode(TranscriptionModelManager.modelID)), .balanced)
        XCTAssertEqual(TranscriptionEngine(metadata: try decode(TranscriptionModelManager.largeModelID)), .precise)
        let unknown = try decode("fixture")
        XCTAssertNil(TranscriptionEngine(metadata: unknown))
        XCTAssertNil(unknown.processingDuration)
    }
}
