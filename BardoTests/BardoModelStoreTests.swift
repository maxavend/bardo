import Foundation
import XCTest
@testable import Bardo

final class BardoModelStoreTests: XCTestCase {
    func testModelRootsStayUnderInjectedRoot() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BardoModelStore(rootURL: root)
        for model in ManagedModel.allCases {
            XCTAssertTrue(store.root(for: model).pathComponents.starts(with: root.standardizedFileURL.pathComponents))
        }
    }

    func testLegacyVoiceCleanupDoesNotTouchQwenOrMeetingMinutes() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BardoStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BardoModelStore(rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["whisper-balanced", "whisper-maximum-accuracy", "parakeet", "qwen", "meeting-minutes"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try store.removeLegacyVoiceModelDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("parakeet").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("qwen").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting-minutes").path))
    }
    func testLegacyQwenCleanupIsExplicitAndLeavesCurrentModelsUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BardoStore-Qwen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BardoModelStore(rootURL: root)
        let qwen = root.appendingPathComponent("qwen", isDirectory: true)
        let minutes = root.appendingPathComponent("meeting-minutes", isDirectory: true)
        try FileManager.default.createDirectory(at: qwen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: minutes, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: qwen.appendingPathComponent("weights.bin"))
        try Data("current".utf8).write(to: minutes.appendingPathComponent("config.json"))

        XCTAssertTrue(store.hasLegacyQwenData())

        try store.removeLegacyQwenData()

        XCTAssertFalse(store.hasLegacyQwenData())
        XCTAssertFalse(FileManager.default.fileExists(atPath: qwen.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: minutes.path))
    }

}
