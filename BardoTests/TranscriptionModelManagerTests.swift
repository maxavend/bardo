import Foundation
import XCTest
@testable import Bardo

private enum TestTokenizerFailure: Error, Sendable {
    case deliberate
}

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

    func testInstalledModelPreparesTokenizerAndReturnsCompleteResources() async throws {
        let modelFolder = rootURL
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        try makeModelSkeleton(at: modelFolder)

        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 },
            prepareTokenizer: { root in
                try Data("ready".utf8).write(to: root.appendingPathComponent("tokenizer-ready"))
            }
        )

        let detected = try await manager.installedModelURL()
        XCTAssertEqual(detected?.standardizedFileURL, modelFolder.standardizedFileURL)

        let resources = try await manager.ensureResourcesAvailable()
        XCTAssertEqual(resources.modelFolder.standardizedFileURL, modelFolder.standardizedFileURL)
        XCTAssertEqual(resources.tokenizerFolder.standardizedFileURL, rootURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("tokenizer-ready").path))
        XCTAssertEqual(await manager.selectedModelID(), TranscriptionModelManager.defaultModelID)
    }

    func testInsufficientDiskSpaceFailsBeforeTokenizerPreparation() async throws {
        let available: Int64 = 100_000_000
        let marker = rootURL.appendingPathComponent("tokenizer-ready")
        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in available },
            prepareTokenizer: { root in
                try Data().write(to: root.appendingPathComponent("tokenizer-ready"))
            }
        )

        do {
            _ = try await manager.ensureResourcesAvailable()
            XCTFail("Expected disk preflight to reject model setup")
        } catch TranscriptionModelError.insufficientDiskSpace(let required, let observedAvailable) {
            XCTAssertEqual(required, TranscriptionModelManager.minimumFreeBytesForDownload)
            XCTAssertEqual(observedAvailable, available)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
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
            availableCapacity: { _ in 0 },
            prepareTokenizer: { _ in }
        )

        XCTAssertNil(try await manager.installedModelURL())
        do {
            _ = try await manager.ensureResourcesAvailable()
            XCTFail("Expected disk preflight after rejecting incomplete model")
        } catch TranscriptionModelError.insufficientDiskSpace {
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
            availableCapacity: { _ in 0 },
            prepareTokenizer: { _ in }
        )

        XCTAssertNil(try await manager.installedModelURL())
        do {
            _ = try await manager.ensureResourcesAvailable()
            XCTFail("Expected invalid model contents to be rejected")
        } catch TranscriptionModelError.insufficientDiskSpace {
        }
    }

    func testTokenizerFailurePreservesInstalledCoreModelForRetry() async throws {
        let modelFolder = rootURL
            .appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        try makeModelSkeleton(at: modelFolder)

        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 },
            prepareTokenizer: { _ in throw TestTokenizerFailure.deliberate }
        )

        do {
            _ = try await manager.ensureResourcesAvailable()
            XCTFail("Expected tokenizer preparation failure")
        } catch TestTokenizerFailure.deliberate {
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: modelFolder.path))
        let detected = try await manager.installedModelURL()
        XCTAssertEqual(detected?.standardizedFileURL, modelFolder.standardizedFileURL)
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
