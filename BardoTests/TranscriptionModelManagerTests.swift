import Foundation
import XCTest
@testable import Bardo

final class TranscriptionModelManagerTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoModelManager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testInstalledModelIsDetectedWithoutDownload() async throws {
        let modelFolder = rootURL
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        try makeModelSkeleton(at: modelFolder)

        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 }
        )

        let detected = try await manager.installedModelURL()
        XCTAssertEqual(detected?.standardizedFileURL, modelFolder.standardizedFileURL)

        let ensured = try await manager.ensureModelAvailable()
        XCTAssertEqual(ensured.standardizedFileURL, modelFolder.standardizedFileURL)
        XCTAssertEqual(await manager.selectedModelID(), TranscriptionModelManager.defaultModelID)
    }

    func testInsufficientDiskSpaceFailsBeforeAnyNetworkDownload() async throws {
        let available: Int64 = 100_000_000
        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in available }
        )

        do {
            _ = try await manager.ensureModelAvailable()
            XCTFail("Expected disk preflight to reject the download")
        } catch TranscriptionModelError.insufficientDiskSpace(let required, let observedAvailable) {
            XCTAssertEqual(required, TranscriptionModelManager.minimumFreeBytesForDownload)
            XCTAssertEqual(observedAvailable, available)
        }
    }

    func testIncompleteModelFolderIsNotTreatedAsInstalled() async throws {
        let incomplete = rootURL
            .appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: incomplete.appendingPathComponent("MelSpectrogram.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )

        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 }
        )

        XCTAssertNil(try await manager.installedModelURL())
        do {
            _ = try await manager.ensureModelAvailable()
            XCTFail("Expected disk preflight after rejecting incomplete model")
        } catch TranscriptionModelError.insufficientDiskSpace {
            // The invalid partial folder is preserved, but it cannot masquerade as ready.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.path))
    }

    func testUnrelatedMLPackagesCannotMasqueradeAsInstalledWhisperModel() async throws {
        let folder = rootURL
            .appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["UnrelatedOne", "UnrelatedTwo", "UnrelatedThree"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(name).mlpackage", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 }
        )

        XCTAssertNil(try await manager.installedModelURL())
        do {
            _ = try await manager.ensureModelAvailable()
            XCTFail("Expected invalid model contents to fall through to disk preflight")
        } catch TranscriptionModelError.insufficientDiskSpace {
            // Expected: unrelated packages are preserved but never considered a ready Whisper model.
        }
    }

    private func makeModelSkeleton(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
