import Foundation
import XCTest
@testable import Bardo

final class MeetingMinutesStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoMeetingMinutesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testSaveLoadDeleteRoundTrip() async throws {
        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let minutes = MeetingMinutes(
            recordingID: recordingID,
            sourceTranscriptMetadata: transcriptMetadata,
            modelID: MeetingMinutesModel.modelID,
            text: "## Summary\n- The team agreed to ship the local build.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_601)
        )
        let recordingStore = RecordingStore(rootURL: rootURL)
        try await recordingStore.save(
            Recording(
                id: recordingID,
                title: "Meeting minutes fixture",
                createdAt: Date(timeIntervalSince1970: 1_700_000_600),
                sources: [.importedFile],
                processingState: .completed,
                audioAssets: []
            )
        )
        let store = MeetingMinutesStore(rootURL: rootURL)

        try await store.save(minutes)
        let loaded = try await store.read(recordingID: recordingID)
        XCTAssertEqual(loaded, minutes)

        try await store.delete(recordingID: recordingID)
        let deleted = try await store.read(recordingID: recordingID)
        XCTAssertNil(deleted)
    }

    func testReadMissingRecordReturnsNil() async throws {
        let store = MeetingMinutesStore(rootURL: rootURL)

        let missing = try await store.read(recordingID: UUID())
        XCTAssertNil(missing)
    }

    private var transcriptMetadata: TranscriptMetadata {
        TranscriptMetadata(
            engine: "WhisperKit",
            engineVersion: "test",
            modelID: "large-v3-v20240930_turbo_632MB",
            createdAt: Date(timeIntervalSince1970: 1_700_000_600)
        )
    }
}
