import Foundation
import XCTest
@testable import Bardo

private enum ParakeetManagerTestError: Error, Sendable {
    case network
    case load
    case cancelled
}

private actor ParakeetOperationRecorder {
    private(set) var downloadPaths: [URL] = []
    private(set) var loadPaths: [URL] = []

    func recordDownload(_ url: URL) {
        downloadPaths.append(url)
    }

    func recordLoad(_ url: URL) {
        loadPaths.append(url)
    }
}

final class ParakeetModelManagerTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bardo-Parakeet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testFirstDownloadFailureUsesOnlyThePrivateRootAndDoesNotRepair() async throws {
        let privateRoot = rootURL.appendingPathComponent("parakeet", isDirectory: true)
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        let marker = privateRoot.appendingPathComponent("partial-download.marker")
        try Data("keep".utf8).write(to: marker)

        let recorder = ParakeetOperationRecorder()
        let operations = ParakeetModelOperations(
            modelsExist: { _ in false },
            download: { url, _ in
                await recorder.recordDownload(url)
                throw ParakeetManagerTestError.network
            },
            load: { url, _ in
                await recorder.recordLoad(url)
                throw ParakeetManagerTestError.load
            }
        )
        let manager = ParakeetModelManager(
            modelRoot: privateRoot,
            operations: operations
        )

        do {
            _ = try await manager.prepareForUse { _ in }
            XCTFail("The first download error should be surfaced")
        } catch ParakeetManagerTestError.network {
            // Expected: a network failure is not a repair trigger.
        }

        let downloadPaths = await recorder.downloadPaths
        let loadPaths = await recorder.loadPaths
        XCTAssertEqual(downloadPaths, [privateRoot])
        XCTAssertTrue(loadPaths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(privateRoot.path.contains("Application Support/FluidAudio"))
    }

    func testCompletePrivateCacheLoadFailureRepairsOnceAndLoadsAgain() async throws {
        let privateRoot = rootURL.appendingPathComponent("parakeet", isDirectory: true)
        let unrelatedRoot = rootURL.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)
        let unrelatedMarker = unrelatedRoot.appendingPathComponent("must-survive.marker")
        try Data("keep".utf8).write(to: unrelatedMarker)

        let recorder = ParakeetOperationRecorder()
        let operations = ParakeetModelOperations(
            modelsExist: { _ in true },
            download: { url, _ in
                await recorder.recordDownload(url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            },
            load: { url, _ in
                await recorder.recordLoad(url)
                throw ParakeetManagerTestError.load
            }
        )
        let manager = ParakeetModelManager(
            modelRoot: privateRoot,
            operations: operations
        )

        do {
            _ = try await manager.prepareForUse { _ in }
            XCTFail("The deliberately failing load should be surfaced after one repair")
        } catch ParakeetManagerTestError.load {
            // Expected: the second load is the final allowed attempt.
        }

        let downloadPaths = await recorder.downloadPaths
        let loadPaths = await recorder.loadPaths
        XCTAssertEqual(downloadPaths, [privateRoot])
        XCTAssertEqual(loadPaths, [privateRoot, privateRoot])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedMarker.path))
    }

    func testFirstDownloadLoadFailureIsNotRepaired() async throws {
        let privateRoot = rootURL.appendingPathComponent("parakeet", isDirectory: true)
        let recorder = ParakeetOperationRecorder()
        let operations = ParakeetModelOperations(
            modelsExist: { url in
                FileManager.default.fileExists(atPath: url.path)
            },
            download: { url, _ in
                await recorder.recordDownload(url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            },
            load: { url, _ in
                await recorder.recordLoad(url)
                throw ParakeetManagerTestError.load
            }
        )
        let manager = ParakeetModelManager(
            modelRoot: privateRoot,
            operations: operations
        )

        do {
            _ = try await manager.prepareForUse { _ in }
            XCTFail("The deliberately failing load should be surfaced")
        } catch ParakeetManagerTestError.load {
            // Expected: an initial download/load failure does not repair.
        }

        let downloadPaths = await recorder.downloadPaths
        let loadPaths = await recorder.loadPaths
        XCTAssertEqual(downloadPaths, [privateRoot])
        XCTAssertEqual(loadPaths, [privateRoot])
    }

    func testCancellationDuringDownloadPreservesPrivateCacheWithoutRepair() async throws {
        let privateRoot = rootURL.appendingPathComponent("parakeet", isDirectory: true)
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        let marker = privateRoot.appendingPathComponent("keep.marker")
        try Data("keep".utf8).write(to: marker)

        let recorder = ParakeetOperationRecorder()
        let operations = ParakeetModelOperations(
            modelsExist: { _ in false },
            download: { url, _ in
                await recorder.recordDownload(url)
                throw ParakeetManagerTestError.cancelled
            },
            load: { url, _ in
                await recorder.recordLoad(url)
                throw ParakeetManagerTestError.load
            }
        )
        let manager = ParakeetModelManager(modelRoot: privateRoot, operations: operations)

        do {
            _ = try await manager.prepareForUse { _ in }
            XCTFail("The cancellation error should be surfaced")
        } catch ParakeetManagerTestError.cancelled {
            // Expected: cancellation is not a repair trigger.
        }

        let downloadPaths = await recorder.downloadPaths
        let loadPaths = await recorder.loadPaths
        XCTAssertEqual(downloadPaths, [privateRoot])
        XCTAssertTrue(loadPaths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}
