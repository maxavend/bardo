import Foundation
import XCTest
@testable import Bardo

private enum TestTokenizerFailure: Error, Sendable {
    case deliberate
}

private actor TokenizerPreparationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
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

    func testCatalogListsTurboAndLargeV3WhisperVariants() {
        XCTAssertEqual(
            TranscriptionModelManager.catalog.map(\.id),
            [
                "large-v3-v20240930_turbo_632MB",
                "large-v3-v20240930_626MB"
            ]
        )
        XCTAssertEqual(
            TranscriptionModelManager.catalog.map(\.displayName),
            ["WhisperKit large-v3 Turbo", "WhisperKit large-v3"]
        )
        XCTAssertEqual(TranscriptionModelManager.catalog.filter(\.isDefault).count, 1)
        XCTAssertTrue(TranscriptionModelManager.catalog.allSatisfy { $0.requiredFreeBytes > 0 })
    }

    func testManagerDefaultsToBalancedWhisperKitSelection() async throws {
        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 },
            prepareTokenizer: { _ in }
        )

        let selectedDefinition = await manager.selectedDefinition()
        XCTAssertEqual(
            selectedDefinition,
            TranscriptionModelDefinition(
                id: "large-v3-v20240930_turbo_632MB",
                displayName: "WhisperKit large-v3 Turbo",
                requiredFreeBytes: 1_500_000_000,
                isDefault: true
            )
        )
        let selectedSelection = await manager.selectedSelection()
        XCTAssertEqual(
            selectedSelection,
            TranscriptionSelection(
                preset: .balanced,
                backend: .whisperKit,
                modelID: "large-v3-v20240930_turbo_632MB"
            )
        )
    }

    func testManagerCanSelectMaximumAccuracyLargeV3() async throws {
        let manager = TranscriptionModelManager(
            definition: TranscriptionModelDefinition(
                id: "large-v3-v20240930_626MB",
                displayName: "WhisperKit large-v3",
                requiredFreeBytes: 1_500_000_000,
                isDefault: false
            ),
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 },
            prepareTokenizer: { _ in }
        )

        let selectedDefinition = await manager.selectedDefinition()
        XCTAssertEqual(selectedDefinition.id, "large-v3-v20240930_626MB")
        let selectedSelection = await manager.selectedSelection()
        XCTAssertEqual(
            selectedSelection,
            TranscriptionSelection(
                preset: .maximumAccuracy,
                backend: .whisperKit,
                modelID: "large-v3-v20240930_626MB"
            )
        )
    }

    func testInstalledModelPreparesTokenizerAndReturnsCompleteResources() async throws {
        let modelFolder = rootURL
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(TranscriptionModelManager.defaultModelID)", isDirectory: true)
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
        let selectedModelID = await manager.selectedModelID()
        XCTAssertEqual(selectedModelID, TranscriptionModelManager.defaultModelID)
    }

    func testPreparedResourcesAreCachedAcrossTranscriptions() async throws {
        let modelFolder = rootURL
            .appendingPathComponent("openai_whisper-\(TranscriptionModelManager.defaultModelID)", isDirectory: true)
        try makeModelSkeleton(at: modelFolder)
        let counter = TokenizerPreparationCounter()

        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 },
            prepareTokenizer: { _ in
                await counter.increment()
            }
        )

        let first = try await manager.ensureResourcesAvailable()
        let second = try await manager.ensureResourcesAvailable()

        XCTAssertEqual(first, second)
        let preparationCount = await counter.value
        XCTAssertEqual(preparationCount, 1, "Tokenizer/cache resolution should not repeat for every short recording")
    }

    func testSuccessfulPreparationPublishesInstalledStateAndFinalProgress() async throws {
        let modelFolder = rootURL
            .appendingPathComponent("openai_whisper-\(TranscriptionModelManager.defaultModelID)", isDirectory: true)
        try makeModelSkeleton(at: modelFolder)
        let progress = ProgressRecorder()

        let manager = TranscriptionModelManager(
            downloadRoot: rootURL,
            availableCapacity: { _ in 0 },
            prepareTokenizer: { _ in }
        )

        let initialState = await manager.state()
        XCTAssertEqual(initialState, .notInstalled)
        _ = try await manager.ensureResourcesAvailable { fraction in
            progress.append(fraction)
        }

        let finalState = await manager.state()
        XCTAssertEqual(finalState, .installed)
        let recordedProgress = progress.values
        XCTAssertEqual(recordedProgress.count, 2)
        XCTAssertEqual(recordedProgress[0], 0.9, accuracy: 0.000_001)
        XCTAssertEqual(recordedProgress[1], 1, accuracy: 0.000_001)
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
            .appendingPathComponent("openai_whisper-\(TranscriptionModelManager.defaultModelID)", isDirectory: true)
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

        let detected = try await manager.installedModelURL()
        XCTAssertNil(detected)
        do {
            _ = try await manager.ensureResourcesAvailable()
            XCTFail("Expected disk preflight after rejecting incomplete model")
        } catch TranscriptionModelError.insufficientDiskSpace {
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.path))
    }

    func testUnrelatedMLPackagesCannotMasqueradeAsInstalledWhisperModel() async throws {
        let folder = rootURL
            .appendingPathComponent("openai_whisper-\(TranscriptionModelManager.defaultModelID)", isDirectory: true)
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

        let detected = try await manager.installedModelURL()
        XCTAssertNil(detected)
        do {
            _ = try await manager.ensureResourcesAvailable()
            XCTFail("Expected invalid model contents to be rejected")
        } catch TranscriptionModelError.insufficientDiskSpace {
        }
    }

    func testTokenizerFailurePreservesInstalledCoreModelForRetry() async throws {
        let modelFolder = rootURL
            .appendingPathComponent("openai_whisper-\(TranscriptionModelManager.defaultModelID)", isDirectory: true)
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

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}
