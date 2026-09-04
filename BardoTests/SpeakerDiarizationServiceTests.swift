import Foundation
import XCTest
import SpeakerKit
@testable import Bardo

final class SpeakerDiarizationServiceTests: XCTestCase {
    func testInstalledModelsRequireCompleteSpeakerKitAssets() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelRoot = BardoModelStore(rootURL: root).root(for: .speakerKit)

        let service = SpeakerDiarizationService(
            modelStore: BardoModelStore(rootURL: root),
            operations: .testLoaded
        )
        let initiallyInstalled = await service.hasInstalledModels()
        XCTAssertFalse(initiallyInstalled)

        for name in [
            "SpeakerSegmenter",
            "SpeakerEmbedderPreprocessor",
            "SpeakerEmbedder",
            "PldaProjector"
        ] {
            let folder = modelRoot.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let fullyInstalled = await service.hasInstalledModels()
        XCTAssertTrue(fullyInstalled)
    }

    func testPartialSpeakerModelCacheIsNotReportedReady() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelRoot = BardoModelStore(rootURL: root).root(for: .speakerKit)

        for name in ["SpeakerSegmenter", "SpeakerEmbedder"] {
            let folder = modelRoot.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let service = SpeakerDiarizationService(
            modelStore: BardoModelStore(rootURL: root),
            operations: .testLoaded
        )
        let installed = await service.hasInstalledModels()
        XCTAssertFalse(installed)
    }

    func testPrepareForUseDownloadsIntoPrivateStoreWhenCacheIsMissing() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SpeakerDiarizationService(
            modelStore: BardoModelStore(rootURL: root),
            operations: .testDownloadable
        )

        try await service.prepareForUse { _ in }

        let installed = await service.hasInstalledModels()
        XCTAssertTrue(installed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: BardoModelStore(rootURL: root).root(for: .speakerKit)
                .appendingPathComponent("SpeakerSegmenter.mlmodelc").path
        ))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSpeakerModels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class LoadedSpeakerDiarizationEngine: SpeakerDiarizationEngine {
    let isLoaded = true

    func downloadModels(progressCallback: (@Sendable (Progress) -> Void)?) async throws {}

    func loadModels() async throws {}

    func diarize(
        audioArray: [Float],
        options: (any DiarizationOptions)?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DiarizationResult {
        fatalError("Diarization is not used by model availability tests")
    }
}

private extension SpeakerDiarizationOperations {
    static let testLoaded = SpeakerDiarizationOperations { _, _ in
        LoadedSpeakerDiarizationEngine()
    }

    static let testDownloadable = SpeakerDiarizationOperations { root, allowsDownload in
        DownloadableSpeakerDiarizationEngine(root: root, allowsDownload: allowsDownload)
    }
}

private final class DownloadableSpeakerDiarizationEngine: SpeakerDiarizationEngine, @unchecked Sendable {
    private let root: URL
    private let allowsDownload: Bool
    private(set) var isLoaded = false

    init(root: URL, allowsDownload: Bool) {
        self.root = root
        self.allowsDownload = allowsDownload
    }

    func downloadModels(progressCallback: (@Sendable (Progress) -> Void)?) async throws {
        precondition(allowsDownload)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["SpeakerSegmenter", "SpeakerEmbedderPreprocessor", "SpeakerEmbedder", "PldaProjector"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        progressCallback?(Progress(totalUnitCount: 1))
    }

    func loadModels() async throws { isLoaded = true }

    func diarize(
        audioArray: [Float],
        options: (any DiarizationOptions)?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DiarizationResult {
        fatalError("Diarization is not used by model availability tests")
    }
}
