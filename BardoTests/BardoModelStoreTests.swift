import Foundation
import XCTest
@testable import Bardo

final class BardoModelStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoModelStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testEveryModelRootIsAChildOfInjectedRoot() throws {
        let store = BardoModelStore(rootURL: rootURL)

        for model in ManagedModel.allCases {
            let modelRoot = store.root(for: model)

            XCTAssertNotEqual(modelRoot.standardizedFileURL, rootURL.standardizedFileURL)
            XCTAssertTrue(
                modelRoot.standardizedFileURL.pathComponents.starts(with: rootURL.standardizedFileURL.pathComponents),
                "\(model) escaped the injected root: \(modelRoot.path)"
            )
        }
    }

    func testParakeetRootDoesNotUseFluidAudioPath() {
        let store = BardoModelStore(rootURL: rootURL)

        XCTAssertFalse(store.root(for: .parakeet).path.contains("FluidAudio"))
    }

    func testResetOnlyRemovesTheSelectedModelDirectory() throws {
        let store = BardoModelStore(rootURL: rootURL)
        let selectedRoot = store.root(for: .whisperBalanced)
        let otherRoot = store.root(for: .speakerKit)
        let unrelatedFile = rootURL.appendingPathComponent("keep-me.txt")

        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: selectedRoot.appendingPathComponent("model.bin"))
        try Data("other".utf8).write(to: otherRoot.appendingPathComponent("model.bin"))
        try Data("unrelated".utf8).write(to: unrelatedFile)

        try store.reset(.whisperBalanced)

        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherRoot.appendingPathComponent("model.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    func testResetRejectsASelectedRootThatResolvesOutsideTheInjectedRoot() throws {
        let store = BardoModelStore(rootURL: rootURL)
        let escapedRoot = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("BardoModelStore-escaped-\(UUID().uuidString)", isDirectory: true)
        let selectedRoot = store.root(for: .parakeet)
        let marker = escapedRoot.appendingPathComponent("must-survive.txt")

        try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: selectedRoot, withDestinationURL: escapedRoot)
        defer { try? FileManager.default.removeItem(at: escapedRoot) }

        XCTAssertThrowsError(try store.reset(.parakeet)) { error in
            XCTAssertEqual(error as? BardoModelStoreError, .invalidModelRoot(.parakeet))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedRoot.path))
    }
}
