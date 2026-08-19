import Foundation
import XCTest
@testable import Bardo

final class SystemAudioCaptureStagingStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSystemAudioStaging-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testActiveCaptureIsHiddenFromRecoveryUntilFinished() async throws {
        let store = SystemAudioCaptureStagingStore(rootURL: rootURL)
        let recordingID = UUID()
        let prepared = try await store.prepareCapture(
            recordingID: recordingID,
            systemAssetID: UUID(),
            microphoneAssetID: UUID(),
            mixAssetID: UUID()
        )
        try Data("partial-system".utf8).write(to: prepared.systemURL)
        try Data("partial-mic".utf8).write(to: try XCTUnwrap(prepared.microphoneURL))

        let activeIssues = try await store.recoveryIssues()
        XCTAssertTrue(activeIssues.isEmpty)

        await store.finishActiveCapture(recordingID: recordingID)
        let issues = try await store.recoveryIssues()
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.recordingID, recordingID)
        XCTAssertEqual(issues.first?.kind, .temporaryAudioArtifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.systemURL.path))
    }

    func testSecondPreparedCaptureIsRejectedAndFirstBytesRemain() async throws {
        let store = SystemAudioCaptureStagingStore(rootURL: rootURL)
        let firstID = UUID()
        let first = try await store.prepareCapture(
            recordingID: firstID,
            systemAssetID: UUID(),
            microphoneAssetID: nil,
            mixAssetID: nil
        )
        try Data("kept".utf8).write(to: first.systemURL)

        do {
            _ = try await store.prepareCapture(
                recordingID: UUID(),
                systemAssetID: UUID(),
                microphoneAssetID: nil,
                mixAssetID: nil
            )
            XCTFail("Expected second staging capture to be rejected")
        } catch SystemAudioCaptureStagingStore.StagingError.captureAlreadyPrepared {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: first.systemURL), Data("kept".utf8))
    }

    func testDiscardRemovesOnlyRequestedCapture() async throws {
        let store = SystemAudioCaptureStagingStore(rootURL: rootURL)
        let recordingID = UUID()
        let prepared = try await store.prepareCapture(
            recordingID: recordingID,
            systemAssetID: UUID(),
            microphoneAssetID: nil,
            mixAssetID: nil
        )
        try Data("temporary".utf8).write(to: prepared.systemURL)

        try await store.discardCapture(recordingID: recordingID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directoryURL.path))
        let issues = try await store.recoveryIssues()
        XCTAssertTrue(issues.isEmpty)
    }
}
