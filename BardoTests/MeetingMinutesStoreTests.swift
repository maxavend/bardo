import Foundation
import XCTest
@testable import Bardo

final class MeetingMinutesStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoMinutes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testSaveAndLoadRoundTrip() async throws {
        let recordingID = UUID()
        let minutes = MeetingMinutes(
            recordingID: recordingID,
            summary: "Se revisó el avance del proyecto.",
            topics: ["Diseño", "Entrega"],
            decisions: [MeetingMinutesItem(text: "Mantener el flujo actual", sourceTime: 42)],
            actionItems: [MeetingActionItem(task: "Preparar prototipo", assignee: "Maxi")],
            openQuestions: [MeetingMinutesItem(text: "¿Cuándo se libera?", sourceTime: 98)],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            engine: "Qwen"
        )
        let store = MeetingMinutesStore(rootURL: rootURL)

        try await store.save(minutes)
        let loaded = try await store.load(recordingID: recordingID)

        XCTAssertEqual(loaded, minutes)
    }

    func testLoadReturnsNilWhenMinutesDoNotExist() async throws {
        let store = MeetingMinutesStore(rootURL: rootURL)

        let loaded = try await store.load(recordingID: UUID())

        XCTAssertNil(loaded)
    }

    func testDeleteRemovesPersistedMinutes() async throws {
        let recordingID = UUID()
        let store = MeetingMinutesStore(rootURL: rootURL)
        let minutes = MeetingMinutes(
            recordingID: recordingID,
            summary: "Resumen",
            engine: "Qwen"
        )
        try await store.save(minutes)

        try await store.delete(recordingID: recordingID)

        XCTAssertNil(try await store.load(recordingID: recordingID))
    }
}
