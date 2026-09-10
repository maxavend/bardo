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

    func testResetRemovesOnlySelectedCurrentModel() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BardoStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BardoModelStore(rootURL: root)
        let whisper = store.root(for: .whisperTurbo)
        let speakers = store.root(for: .speakerKit)
        try FileManager.default.createDirectory(at: whisper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: speakers, withIntermediateDirectories: true)
        try Data("whisper".utf8).write(to: whisper.appendingPathComponent("marker"))
        try Data("speakers".utf8).write(to: speakers.appendingPathComponent("marker"))

        try store.reset(.whisperTurbo)

        XCTAssertFalse(FileManager.default.fileExists(atPath: whisper.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: speakers.path))
    }

    func testLegacyVoiceCleanupLeavesCurrentModelsUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BardoStore-Legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BardoModelStore(rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["whisper-balanced", "whisper-maximum-accuracy", "parakeet"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: store.root(for: .whisperTurbo), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.root(for: .speakerKit), withIntermediateDirectories: true)

        try store.removeLegacyVoiceModelDirectories()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("whisper-balanced").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("whisper-maximum-accuracy").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("parakeet").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root(for: .whisperTurbo).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root(for: .speakerKit).path))
    }
}
