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

    func testTranscriptionOptionsMapUserFacingChoicesToBackends() {
        XCTAssertEqual(
            TranscriptionOption.catalog.map(\.preset),
            [.instant, .balanced, .maximumAccuracy]
        )
        XCTAssertEqual(TranscriptionOption.option(for: .instant).selection.backend, .parakeet)
        XCTAssertEqual(TranscriptionOption.option(for: .instant).selection.modelID, TranscriptionBackend.parakeetModelID)
        XCTAssertEqual(TranscriptionOption.option(for: .balanced).selection.modelID, TranscriptionModelManager.balancedModelID)
        XCTAssertEqual(TranscriptionOption.option(for: .maximumAccuracy).selection.modelID, TranscriptionModelManager.maximumAccuracyModelID)
        XCTAssertEqual(TranscriptionOption.option(for: .instant).label, "Instant (Parakeet)")
        XCTAssertEqual(TranscriptionOption.option(for: .balanced).label, "Default (Whisper Turbo)")
        XCTAssertEqual(TranscriptionOption.option(for: .maximumAccuracy).label, "Más presición (Whisper Large)")
    }

    func testTranscriptionPreferenceStoreDefaultsToBalancedAndPersistsSelection() {
        let suiteName = "Bardo.TranscriptionPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranscriptionPreferenceStore(defaults: defaults)

        XCTAssertEqual(store.selectedPreset(), .balanced)

        store.setSelectedPreset(.instant)
        XCTAssertEqual(store.selectedPreset(), .instant)
    }

    func testTranscriptMetadataPreservesSelectionThroughCodableRoundTrip() throws {
        let recordingID = UUID()
        let selection = TranscriptionOption.option(for: .balanced).selection
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
