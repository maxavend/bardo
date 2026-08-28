import Foundation
import XCTest
@testable import Bardo

final class SpeakerDiarizationServiceTests: XCTestCase {
    func testInstalledModelsRequireCompleteSpeakerKitAssets() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SpeakerDiarizationService(modelRoot: root)
        XCTAssertFalse(await service.hasInstalledModels())

        for name in [
            "SpeakerSegmenter",
            "SpeakerEmbedderPreprocessor",
            "SpeakerEmbedder",
            "PldaProjector"
        ] {
            let folder = root.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        XCTAssertTrue(await service.hasInstalledModels())
    }

    func testPartialSpeakerModelCacheIsNotReportedReady() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["SpeakerSegmenter", "SpeakerEmbedder"] {
            let folder = root.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let service = SpeakerDiarizationService(modelRoot: root)
        XCTAssertFalse(await service.hasInstalledModels())
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSpeakerModels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
