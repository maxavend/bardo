import Foundation
import XCTest

@testable import Bardo

final class MicrophoneCaptureStagingStoreTests: XCTestCase {
    func testOnlyOneCaptureCanBePreparedPerStagingStore() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = MicrophoneCaptureStagingStore(rootURL: rootURL)
        let firstID = UUID()

        _ = try await store.prepareCapture(
            recordingID: firstID,
            audioAssetID: UUID(),
            fileExtension: "wav"
        )

        do {
            _ = try await store.prepareCapture(
                recordingID: UUID(),
                audioAssetID: UUID(),
                fileExtension: "wav"
            )
            XCTFail("Expected a second active staging capture to be rejected")
        } catch MicrophoneCaptureStagingError.captureAlreadyActive(let activeID) {
            XCTAssertEqual(activeID, firstID)
        }

        await store.preserveInterruptedCapture(recordingID: firstID)
    }

    func testActiveCaptureIsNotRecoveryResidueUntilInterrupted() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = MicrophoneCaptureStagingStore(rootURL: rootURL)
        let recordingID = UUID()
        let stagedURL = try await store.prepareCapture(
            recordingID: recordingID,
            audioAssetID: UUID(),
            fileExtension: "wav"
        )
        try Data("partial microphone bytes".utf8).write(to: stagedURL)

        let activeIssues = await store.recoveryIssues()
        XCTAssertTrue(activeIssues.isEmpty)

        await store.preserveInterruptedCapture(recordingID: recordingID)
        let interruptedIssues = await store.recoveryIssues()
        XCTAssertEqual(interruptedIssues.count, 1)
        XCTAssertEqual(interruptedIssues.first?.recordingID, recordingID)

        let freshStore = MicrophoneCaptureStagingStore(rootURL: rootURL)
        let restartIssues = await freshStore.recoveryIssues()
        XCTAssertEqual(restartIssues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testDiscardRemovesOnlyPreparedCapture() async throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = MicrophoneCaptureStagingStore(rootURL: rootURL)
        let recordingID = UUID()
        let stagedURL = try await store.prepareCapture(
            recordingID: recordingID,
            audioAssetID: UUID(),
            fileExtension: "wav"
        )
        try Data("preparation".utf8).write(to: stagedURL)

        try await store.discardPreparedCapture(recordingID: recordingID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        let remainingIssues = await store.recoveryIssues()
        XCTAssertTrue(remainingIssues.isEmpty)
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoMicrophoneStagingTests-\(UUID().uuidString)", isDirectory: true)
    }
}
