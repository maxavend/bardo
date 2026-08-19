import Foundation
import XCTest
@testable import Bardo

final class Phase1IntegrationTests: XCTestCase {
    @MainActor
    func testLibraryRebuildsFromDiskAndSurvivesOneCorruptRecording() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase1Integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let a = Recording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            title: "A",
            createdAt: Date(timeIntervalSince1970: 1_700_000_800),
            duration: 15,
            sources: [.microphone]
        )
        let bID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let c = Recording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
            title: "C",
            createdAt: Date(timeIntervalSince1970: 1_700_000_900),
            duration: 30,
            sources: [.systemAudio]
        )

        let firstProcessStore = RecordingStore(rootURL: rootURL)
        try await firstProcessStore.save(a)
        try await firstProcessStore.save(c)

        let bDirectory = rootURL.appendingPathComponent(bID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bDirectory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(
            to: bDirectory.appendingPathComponent(RecordingStore.manifestFileName)
        )

        let restartedProcessStore = RecordingStore(rootURL: rootURL)
        let restartedLibrary = LibraryViewModel(store: restartedProcessStore)
        await restartedLibrary.reload()

        XCTAssertEqual(restartedLibrary.recordings, [c, a])
        XCTAssertEqual(restartedLibrary.issues.count, 1)
        XCTAssertEqual(restartedLibrary.issues.first?.kind, .corruptManifest)
        XCTAssertEqual(restartedLibrary.issues.first?.recordingID, bID)
        XCTAssertNil(restartedLibrary.errorMessage)
        XCTAssertEqual(restartedLibrary.selection, c.id)
    }
}
