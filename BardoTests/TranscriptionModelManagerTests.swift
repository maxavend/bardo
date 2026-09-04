import Foundation
import XCTest
@testable import Bardo

final class TranscriptionModelManagerTests: XCTestCase {
    func testOnlyTurboModelIsExposed() async {
        let manager = TranscriptionModelManager(
            downloadRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("BardoWhisper-\(UUID().uuidString)")
        )
        let selectedModelID = await manager.selectedModelID()
        let selectedDefinition = await manager.selectedDefinition()
        let selectedSelection = await manager.selectedSelection()

        XCTAssertEqual(selectedModelID, TranscriptionModelManager.modelID)
        XCTAssertEqual(
            selectedDefinition,
            TranscriptionModelDefinition(id: TranscriptionModelManager.modelID, displayName: "WhisperKit large-v3 Turbo")
        )
        XCTAssertEqual(selectedSelection, TranscriptionSelection())
    }

    func testRuntimeManagerUsesPrivateDownloadRootAndStartsUninstalled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoWhisper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TranscriptionModelManager(downloadRoot: root)

        let modelRoot = await manager.modelRootURL()
        let installed = try await manager.hasInstalledModel()
        XCTAssertEqual(modelRoot.path, root.standardizedFileURL.path)
        XCTAssertFalse(installed)
    }

    func testPerformanceProfileUsesConservativeAppleSiliconDefaults() {
        let profile = WhisperPerformanceProfile(physicalMemory: 16 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(profile.incrementalChunkDurationSeconds, 120)
        XCTAssertEqual(profile.maxBufferedChunks, 2)
        XCTAssertEqual(profile.concurrentWorkerCount, 8)
        XCTAssertTrue(profile.usesVAD)
        XCTAssertEqual(profile.temperatureFallbackCount, 5)
    }

    func testRuntimeDownloadChecksCapacityBeforeStarting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoWhisper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TranscriptionModelManager(
            downloadRoot: root,
            availableCapacity: { _ in 0 }
        )

        do {
            _ = try await manager.ensureResourcesAvailable()
            XCTFail("Expected the private download to stop before network access")
        } catch let error as TranscriptionModelError {
            XCTAssertEqual(
                error,
                .insufficientDiskSpace(
                    requiredBytes: TranscriptionModelManager.minimumFreeBytesForDownload,
                    availableBytes: 0
                )
            )
        }
    }
}
