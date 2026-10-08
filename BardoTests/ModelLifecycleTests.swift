import Foundation
import SpeakerKit
import XCTest
@testable import Bardo

// MARK: - First-run setup

@MainActor
final class TranscriptionSetupCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "BardoSetupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testFreshInstallKeepsLibraryLockedUntilTheUserChoosesToContinue() {
        let coordinator = TranscriptionSetupCoordinator(defaults: defaults, services: FakeSetupServices())
        XCTAssertFalse(coordinator.isLibraryUnlocked)

        coordinator.unlockLibrary()

        XCTAssertTrue(coordinator.isLibraryUnlocked)
        let relaunched = TranscriptionSetupCoordinator(defaults: defaults, services: FakeSetupServices())
        XCTAssertTrue(relaunched.isLibraryUnlocked, "Choosing to continue must survive relaunches")
    }

    func testOfflineFirstRunFailsWithoutBlockingTheLibraryChoice() async {
        let services = FakeSetupServices()
        services.transcriptionFailure = URLError(.notConnectedToInternet)
        let coordinator = TranscriptionSetupCoordinator(defaults: defaults, services: services)

        await coordinator.prepareIfNeeded()

        guard case .failed = coordinator.state else {
            return XCTFail("Expected a visible failure, got \(coordinator.state)")
        }
        coordinator.unlockLibrary()
        XCTAssertTrue(coordinator.isLibraryUnlocked)
    }

    func testSuccessfulSetupUnlocksTheLibraryAndWarmsTranscription() async {
        let services = FakeSetupServices()
        let coordinator = TranscriptionSetupCoordinator(defaults: defaults, services: services)

        await coordinator.prepareIfNeeded()

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.isLibraryUnlocked)
        XCTAssertEqual(services.preparedTranscription, 1)
        XCTAssertEqual(services.preparedSpeakers, 1)
        XCTAssertGreaterThanOrEqual(services.warmedTranscription, 1)
    }

    func testInstalledModelsSkipDownloadsEvenAfterASetupVersionChange() async {
        let services = FakeSetupServices()
        services.transcriptionInstalled = true
        services.speakersInstalled = true
        let coordinator = TranscriptionSetupCoordinator(defaults: defaults, services: services)

        await coordinator.prepareIfNeeded()

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(coordinator.isLibraryUnlocked)
        XCTAssertEqual(services.preparedTranscription, 0)
    }

    func testRemovedModelsAreOfferedAgainInsteadOfSilentlyDownloaded() async {
        let services = FakeSetupServices()
        let first = TranscriptionSetupCoordinator(defaults: defaults, services: services)
        await first.prepareIfNeeded()
        XCTAssertEqual(first.state, .ready)

        // The user removes the models from Settings; the next launch must not block.
        try? await services.resetAll()
        let relaunched = TranscriptionSetupCoordinator(defaults: defaults, services: services)
        XCTAssertTrue(relaunched.isLibraryUnlocked)
        await relaunched.prepareIfNeeded()

        XCTAssertEqual(relaunched.state, .needsInstall)
        XCTAssertTrue(relaunched.isLibraryUnlocked)
        XCTAssertEqual(services.preparedTranscription, 1, "No download without asking")

        await relaunched.prepareIfNeeded(force: true)
        XCTAssertEqual(relaunched.state, .ready)
        XCTAssertEqual(services.preparedTranscription, 2)
    }

    func testPausingSetupReportsCancelledState() async {
        let services = FakeSetupServices()
        services.transcriptionDelay = .seconds(5)
        let coordinator = TranscriptionSetupCoordinator(defaults: defaults, services: services)

        coordinator.startPreparation()
        for _ in 0..<50 where services.preparedTranscription == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        coordinator.cancelPreparation()
        for _ in 0..<100 where coordinator.isWorking {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.state, .cancelled)
        XCTAssertFalse(coordinator.isLibraryUnlocked)
    }
}

private final class FakeSetupServices: TranscriptionSetupServices, @unchecked Sendable {
    private let lock = NSLock()
    var transcriptionInstalled = false
    var speakersInstalled = false
    var transcriptionFailure: Error?
    var transcriptionDelay: Duration = .zero
    private(set) var preparedTranscription = 0
    private(set) var preparedSpeakers = 0
    private(set) var warmedTranscription = 0

    func removeLegacyModels() throws {}

    func isTranscriptionInstalled() async -> Bool { lock.bardoWithLock { transcriptionInstalled } }

    func areSpeakersInstalled() async -> Bool { lock.bardoWithLock { speakersInstalled } }

    func prepareTranscription(progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void) async throws {
        let (failure, delay) = lock.bardoWithLock {
            preparedTranscription += 1
            return (transcriptionFailure, transcriptionDelay)
        }
        progress(.init(stage: .downloading, fractionCompleted: 0.5))
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        lock.bardoWithLock { transcriptionInstalled = true }
    }

    func prepareSpeakers(progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void) async throws {
        lock.bardoWithLock {
            preparedSpeakers += 1
            speakersInstalled = true
        }
    }

    func warmUpTranscription() async { lock.bardoWithLock { warmedTranscription += 1 } }

    func warmUpSpeakers() async {}

    func resetAll() async throws {
        lock.bardoWithLock {
            transcriptionInstalled = false
            speakersInstalled = false
        }
    }
}

// MARK: - Shared operations

final class ModelOperationSupportTests: XCTestCase {
    func testCancelledWaiterReturnsPromptlyWhileWorkKeepsRunning() async throws {
        let work = Task<Int, Error> {
            try? await Task.sleep(for: .seconds(2))
            return 42
        }
        let waiter = Task {
            try await CancellableAwait.value(of: work, cancelUnderlyingTask: false)
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("The waiter must observe its cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
        XCTAssertFalse(work.isCancelled)
        work.cancel()
    }

    func testLateProgressObserversReceiveTheLatestValue() {
        let fanOut = ProgressFanOut<Double>()
        fanOut.send(0.4)
        let received = LockedValues()
        let id = fanOut.add { received.append($0) }
        fanOut.send(0.7)
        fanOut.remove(id)
        fanOut.send(0.9)

        XCTAssertEqual(received.values, [0.4, 0.7])
    }

    func testConcurrentWhisperRequestsShareOneDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoWhisperSingleFlight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = Counter()
        let manager = TranscriptionModelManager(
            downloadRoot: root,
            availableCapacity: { _ in Int64.max },
            prepareTokenizer: { root in
                try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
            },
            downloadModel: { variant, root, progress in
                downloads.increment()
                try await Task.sleep(for: .milliseconds(200))
                let folder = root.appendingPathComponent("models/\(variant)", isDirectory: true)
                for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
                    try FileManager.default.createDirectory(
                        at: folder.appendingPathComponent("\(name).mlmodelc"),
                        withIntermediateDirectories: true
                    )
                }
                progress(1)
                return folder
            }
        )

        async let first = manager.ensureResourcesAvailable()
        async let second = manager.ensureResourcesAvailable()
        let (a, b) = try await (first, second)

        XCTAssertEqual(a, b)
        XCTAssertEqual(downloads.value, 1, "Concurrent callers must not download into the same folder twice")
        let isPreparing = await manager.isPreparing
        XCTAssertFalse(isPreparing)
    }

    func testCancellingAWhisperDownloadLetsTheNextRequestStartCleanly() async throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BardoWhisperCancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = Counter()
        let manager = TranscriptionModelManager(
            downloadRoot: root,
            availableCapacity: { _ in Int64.max },
            prepareTokenizer: { root in
                try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
            },
            downloadModel: { variant, root, _ in
                let attempt = downloads.increment()
                if attempt == 1 { try await Task.sleep(for: .seconds(10)) }
                let folder = root.appendingPathComponent("models/\(variant)", isDirectory: true)
                for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
                    try FileManager.default.createDirectory(
                        at: folder.appendingPathComponent("\(name).mlmodelc"),
                        withIntermediateDirectories: true
                    )
                }
                return folder
            }
        )

        let paused = Task { try await manager.ensureResourcesAvailable() }
        try await Task.sleep(for: .milliseconds(100))
        paused.cancel()
        do {
            _ = try await paused.value
            XCTFail("Pausing must cancel the download")
        } catch is CancellationError {}

        let resumed = try await manager.ensureResourcesAvailable()
        XCTAssertTrue(resumed.modelFolder.path.hasSuffix(TranscriptionModelManager.modelID))
        XCTAssertEqual(downloads.value, 2)
        let resetError: Error? = await {
            do { try await manager.reset(); return nil } catch { return error }
        }()
        XCTAssertNil(resetError, "A finished download must not keep the model marked in use")
    }
}

// MARK: - Speaker identification

final class SpeakerDiarizationLifecycleTests: XCTestCase {
    func testConcurrentPreparationsDownloadOnce() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = Counter()
        let service = SpeakerDiarizationService(
            modelStore: BardoModelStore(rootURL: root),
            operations: SpeakerDiarizationOperations { modelRoot, allowsDownload in
                SlowSpeakerEngine(root: modelRoot, allowsDownload: allowsDownload, downloads: downloads)
            }
        )

        async let first: Void = service.prepareForUse { _ in }
        async let second: Void = service.prepareForUse { _ in }
        async let warmUp: Void = service.warmUpIfInstalled()
        _ = try await (first, second, warmUp)

        XCTAssertEqual(downloads.value, 1)
        let installed = await service.hasInstalledModels()
        XCTAssertTrue(installed)
    }

    func testCancellingSpeakerIdentificationReturnsPromptlyAndBlocksResetUntilDone() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        let store = RecordingStore(rootURL: libraryURL)
        let source = root.appendingPathComponent("speech.wav")
        try AudioTestFixture.makeWAV(at: source, sampleRate: 16_000, duration: 1)
        let recording = try await AudioImportService(store: store).importFile(at: source)
        let transcript = Transcript(
            recordingID: recording.id,
            languageCode: "es",
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Hola")],
            metadata: TranscriptMetadata(engine: "Test", engineVersion: "1", modelID: "test")
        )

        let downloads = Counter()
        let service = SpeakerDiarizationService(
            modelStore: BardoModelStore(rootURL: root.appendingPathComponent("Models")),
            operations: SpeakerDiarizationOperations { modelRoot, allowsDownload in
                SlowSpeakerEngine(root: modelRoot, allowsDownload: allowsDownload, downloads: downloads)
            }
        )
        try await service.prepareForUse { _ in }

        let diarization = Task {
            try await service.diarize(recording: recording, transcript: transcript, store: store) { _ in }
        }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        diarization.cancel()
        do {
            _ = try await diarization.value
            XCTFail("Cancelled speaker identification must not publish a result")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(1))

        do {
            try await service.reset()
            XCTFail("Models must not be removed while an inference is still running")
        } catch ModelOperationError.inUse {}
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoSpeakerLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

/// A speaker engine whose download is slow and whose inference ignores cancellation,
/// like SpeakerKit's internal pipeline.
private final class SlowSpeakerEngine: SpeakerDiarizationEngine, @unchecked Sendable {
    private let root: URL
    private let allowsDownload: Bool
    private let downloads: Counter
    private let lock = NSLock()
    private var loaded = false

    init(root: URL, allowsDownload: Bool, downloads: Counter) {
        self.root = root
        self.allowsDownload = allowsDownload
        self.downloads = downloads
    }

    var isLoaded: Bool { lock.bardoWithLock { loaded } }

    func downloadModels(progressCallback: (@Sendable (Progress) -> Void)?) async throws {
        precondition(allowsDownload)
        downloads.increment()
        try await Task.sleep(for: .milliseconds(150))
        for name in ["SpeakerSegmenter", "SpeakerEmbedderPreprocessor", "SpeakerEmbedder", "PldaProjector"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func loadModels() async throws {
        lock.bardoWithLock { loaded = true }
    }

    func diarize(
        audioArray: [Float],
        options: (any DiarizationOptions)?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DiarizationResult {
        // Busy work that never checks for cancellation.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { usleep(10_000) }
        throw RecordingDiarizationError.noSpeakerActivity
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.bardoWithLock { count } }

    @discardableResult
    func increment() -> Int {
        lock.bardoWithLock {
            count += 1
            return count
        }
    }
}

private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] { lock.bardoWithLock { stored } }

    func append(_ value: Double) {
        lock.bardoWithLock { stored.append(value) }
    }
}
