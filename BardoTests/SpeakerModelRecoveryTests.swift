import Foundation
import XCTest
@preconcurrency import SpeakerKit
@testable import Bardo

final class SpeakerModelRecoveryTests: XCTestCase {
    func testCompleteCacheIsNotInstalledWhenEngineDoesNotBecomeLoaded() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BardoModelStore(rootURL: root)
        try installCompleteCache(in: store)

        let recorder = EngineRecorder()
        let engine = TestSpeakerDiarizationEngine(
            isLoaded: false,
            download: { _ in XCTFail("validation must not download") },
            load: {},
            recorder: recorder
        )
        let service = SpeakerDiarizationService(
            modelStore: store,
            operations: SpeakerDiarizationOperations(makeEngine: { _, _ in engine })
        )

        let installed = await service.hasInstalledModels()

        XCTAssertFalse(installed)
        XCTAssertEqual(recorder.loadCalls, 1)
        let state = await service.state()
        XCTAssertEqual(state, .failed("Bardo could not load the private SpeakerKit models. Reset the SpeakerKit models and download them again."))
    }

    func testCompleteCacheLoadFailureInvalidatesEngineAndRepairsExactlyOnce() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BardoModelStore(rootURL: root)
        try installCompleteCache(in: store)

        let recorder = EngineRecorder()
        let failingValidationEngine = TestSpeakerDiarizationEngine(
            isLoaded: false,
            download: { _ in XCTFail("validation must not download") },
            load: { throw TestSpeakerError.load },
            recorder: recorder
        )
        let repairedEngine = TestSpeakerDiarizationEngine(
            isLoaded: true,
            download: { _ in try installCompleteCache(in: store) },
            load: {},
            recorder: recorder
        )
        let operations = SpeakerDiarizationOperations(
            makeEngine: { _, allowsDownload in
                allowsDownload ? repairedEngine : failingValidationEngine
            }
        )
        let service = SpeakerDiarizationService(modelStore: store, operations: operations)

        try await service.prepareForUse { _ in }

        XCTAssertEqual(recorder.createdEngines, 2)
        XCTAssertEqual(recorder.downloadCalls, 1)
        XCTAssertEqual(recorder.loadCalls, 2)
        let installed = await service.hasInstalledModels()
        XCTAssertTrue(installed)
    }

    func testFirstDownloadNetworkFailurePreservesPartialCache() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BardoModelStore(rootURL: root)
        let partialMarker = store.root(for: .speakerKit).appendingPathComponent("partial.marker")
        try FileManager.default.createDirectory(
            at: store.root(for: .speakerKit),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: partialMarker)

        let engine = TestSpeakerDiarizationEngine(
            isLoaded: false,
            download: { _ in throw URLError(.notConnectedToInternet) },
            load: {},
            recorder: EngineRecorder()
        )
        let service = SpeakerDiarizationService(
            modelStore: store,
            operations: SpeakerDiarizationOperations(makeEngine: { _, _ in engine })
        )

        do {
            try await service.prepareForUse { _ in }
            XCTFail("Expected the first download to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialMarker.path))
    }

    func testCancellationDuringFirstDownloadPreservesCacheAndDoesNotLoad() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BardoModelStore(rootURL: root)
        let marker = store.root(for: .speakerKit).appendingPathComponent("partial.marker")
        try FileManager.default.createDirectory(
            at: store.root(for: .speakerKit),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: marker)

        let recorder = EngineRecorder()
        let engine = TestSpeakerDiarizationEngine(
            isLoaded: false,
            download: { _ in throw CancellationError() },
            load: {},
            recorder: recorder
        )
        let service = SpeakerDiarizationService(
            modelStore: store,
            operations: SpeakerDiarizationOperations(makeEngine: { _, _ in engine })
        )

        do {
            try await service.prepareForUse { _ in }
            XCTFail("Expected the first download to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.loadCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWarmupLeavesActionableFailedStateAfterRepairLoadFailure() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BardoModelStore(rootURL: root)
        try installCompleteCache(in: store)

        let recorder = EngineRecorder()
        let engine = TestSpeakerDiarizationEngine(
            isLoaded: false,
            download: { _ in try installCompleteCache(in: store) },
            load: { throw TestSpeakerError.load },
            recorder: recorder
        )
        let service = SpeakerDiarizationService(
            modelStore: store,
            operations: SpeakerDiarizationOperations(makeEngine: { _, _ in engine })
        )

        await service.warmUpIfInstalled()

        let state = await service.state()
        XCTAssertEqual(state, .failed("SpeakerKit test load failure"))
        XCTAssertEqual(recorder.downloadCalls, 1)
        XCTAssertEqual(recorder.loadCalls, 2)
    }

    func testRecoveryDecisionDelegatesToSharedPolicy() {
        XCTAssertEqual(
            SpeakerDiarizationService.recoveryDecision(
                wasComplete: true,
                phase: .loading,
                isCancellation: false,
                errorKind: .load
            ),
            .retryLoadAfterRepair
        )
        XCTAssertEqual(
            SpeakerDiarizationService.recoveryDecision(
                wasComplete: false,
                phase: .downloading,
                isCancellation: true,
                errorKind: .network
            ),
            .cancelled
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSpeakerRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func installCompleteCache(in store: BardoModelStore) throws {
        let modelRoot = store.root(for: .speakerKit)
        for name in [
            "SpeakerSegmenter",
            "SpeakerEmbedderPreprocessor",
            "SpeakerEmbedder",
            "PldaProjector"
        ] {
            try FileManager.default.createDirectory(
                at: modelRoot.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}

private enum TestSpeakerError: Error, LocalizedError, Sendable {
    case load

    var errorDescription: String? {
        "SpeakerKit test load failure"
    }
}

private final class EngineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var createdEngines = 0
    private(set) var downloadCalls = 0
    private(set) var loadCalls = 0

    func recordCreation() {
        lock.lock()
        defer { lock.unlock() }
        createdEngines += 1
    }

    func recordDownload() {
        lock.lock()
        defer { lock.unlock() }
        downloadCalls += 1
    }

    func recordLoad() {
        lock.lock()
        defer { lock.unlock() }
        loadCalls += 1
    }
}

private final class TestSpeakerDiarizationEngine: SpeakerDiarizationEngine, @unchecked Sendable {
    let isLoaded: Bool
    private let downloadOperation: @Sendable (Progress?) async throws -> Void
    private let loadOperation: @Sendable () async throws -> Void
    private let recorder: EngineRecorder

    init(
        isLoaded: Bool,
        download: @escaping @Sendable (Progress?) async throws -> Void,
        load: @escaping @Sendable () async throws -> Void,
        recorder: EngineRecorder
    ) {
        self.isLoaded = isLoaded
        self.downloadOperation = download
        self.loadOperation = load
        self.recorder = recorder
        recorder.recordCreation()
    }

    func downloadModels(progressCallback: (@Sendable (Progress) -> Void)?) async throws {
        recorder.recordDownload()
        try await downloadOperation(progressCallback)
    }

    func loadModels() async throws {
        recorder.recordLoad()
        try await loadOperation()
    }

    func diarize(
        audioArray: [Float],
        options: (any DiarizationOptions)?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DiarizationResult {
        throw TestSpeakerError.load
    }
}

private extension SpeakerDiarizationOperations {
    static let testLoaded = SpeakerDiarizationOperations(
        makeEngine: { _, _ in
            TestSpeakerDiarizationEngine(
                isLoaded: true,
                download: { _ in },
                load: {},
                recorder: EngineRecorder()
            )
        }
    )
}
