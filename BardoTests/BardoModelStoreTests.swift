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
}
