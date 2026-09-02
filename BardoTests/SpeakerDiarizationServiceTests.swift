import Foundation
import XCTest
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

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSpeakerModels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
