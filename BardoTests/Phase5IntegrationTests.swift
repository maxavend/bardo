import Foundation
import XCTest
@testable import Bardo

private enum StubTranscriptionError: Error, LocalizedError, Sendable {
    case deliberate

    var errorDescription: String? { "Deliberate transcription failure" }
}

private struct StubRecordingTranscriber: RecordingTranscribing {
    let shouldFail: Bool

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        progress(.init(stage: .transcribing, fractionCompleted: 0.5))
        if shouldFail { throw StubTranscriptionError.deliberate }
        progress(.init(stage: .transcribing, fractionCompleted: 1))
        return Transcript(
            recordingID: recording.id,
            languageCode: "en",
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 1,
                    text: "Phase five works.",
                    words: [
                        TranscriptWord(startTime: 0, endTime: 0.3, text: "Phase", probability: 0.99),
                        TranscriptWord(startTime: 0.3, endTime: 0.6, text: "five", probability: 0.98),
                        TranscriptWord(startTime: 0.6, endTime: 1, text: "works.", probability: 0.97)
                    ]
                )
            ],
            metadata: TranscriptMetadata(
                engine: "Test",
                engineVersion: "1",
                modelID: "fixture",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }
}

private struct SlowRecordingTranscriber: RecordingTranscribing {
    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        progress(.init(stage: .transcribing, fractionCompleted: 0.1))
        try await Task.sleep(for: .seconds(30))
        return Transcript(
            recordingID: recording.id,
            segments: [],
            metadata: TranscriptMetadata(engine: "Test", engineVersion: "1", modelID: "fixture")
        )
    }
}

final class Phase5IntegrationTests: XCTestCase {
    private var rootURL: URL!
    private var sourceURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase5Source-\(UUID().uuidString).wav")
        try AudioTestFixture.makeWAV(at: sourceURL, sampleRate: 16_000, duration: 1)
    }

    override func tearDownWithError() throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        if let sourceURL { try? FileManager.default.removeItem(at: sourceURL) }
        rootURL = nil
        sourceURL = nil
    }

    @MainActor
    func testTranscriptPersistsAcrossFreshStoreAndOriginalSourceCanDisappear() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        let transcriptStore = TranscriptStore(rootURL: rootURL)
        let model = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore,
            transcriber: StubRecordingTranscriber(shouldFail: false)
        )

        await model.reload()
        XCTAssertEqual(model.selection, recording.id)
        await model.performSelectedTranscription()

        XCTAssertEqual(model.selectedRecording?.processingState, .completed)
        XCTAssertEqual(model.transcript?.text, "Phase five works.")
        XCTAssertNil(model.transcriptErrorMessage)

        try FileManager.default.removeItem(at: sourceURL)

        let restartedRecordingStore = RecordingStore(rootURL: rootURL)
        let restartedModel = LibraryViewModel(
            store: restartedRecordingStore,
            transcriptStore: TranscriptStore(rootURL: rootURL),
            transcriber: StubRecordingTranscriber(shouldFail: true)
        )
        await restartedModel.reload()

        XCTAssertEqual(restartedModel.selectedRecording?.id, recording.id)
        XCTAssertEqual(restartedModel.selectedRecording?.processingState, .completed)
        XCTAssertEqual(restartedModel.transcript?.text, "Phase five works.")

        let asset = try XCTUnwrap(restartedModel.selectedRecording?.audioAssets.first)
        let managedURL = try await restartedRecordingStore.managedAudioURL(
            recordingID: recording.id,
            audioAssetID: asset.id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
    }

    @MainActor
    func testTranscriptionFailurePreservesManagedAudioAndMarksRecordingRetryable() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        let model = LibraryViewModel(
            store: store,
            transcriptStore: TranscriptStore(rootURL: rootURL),
            transcriber: StubRecordingTranscriber(shouldFail: true)
        )

        await model.reload()
        await model.performSelectedTranscription()

        XCTAssertEqual(model.selectedRecording?.processingState, .failed)
        XCTAssertNotNil(model.transcriptErrorMessage)
        XCTAssertNil(model.transcript)

        let persisted = try await RecordingStore(rootURL: rootURL).read(id: recording.id)
        XCTAssertEqual(persisted.processingState, .failed)
        let asset = try XCTUnwrap(persisted.audioAssets.first)
        _ = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
    }

    @MainActor
    func testFailedRecordingCanRetryAndPersistSuccessfulTranscript() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        let transcriptStore = TranscriptStore(rootURL: rootURL)

        let failingModel = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore,
            transcriber: StubRecordingTranscriber(shouldFail: true)
        )
        await failingModel.reload()
        await failingModel.performSelectedTranscription()
        XCTAssertEqual(failingModel.selectedRecording?.processingState, .failed)

        let retryModel = LibraryViewModel(
            store: RecordingStore(rootURL: rootURL),
            transcriptStore: TranscriptStore(rootURL: rootURL),
            transcriber: StubRecordingTranscriber(shouldFail: false)
        )
        await retryModel.reload()
        await retryModel.performSelectedTranscription()

        XCTAssertEqual(retryModel.selectedRecording?.processingState, .completed)
        let persistedTranscript = try await TranscriptStore(rootURL: rootURL).read(recordingID: recording.id)
        XCTAssertEqual(persistedTranscript?.text, "Phase five works.")
    }

    @MainActor
    func testCancellationReturnsRecordingToPendingWithoutPublishingFalseTranscript() async throws {
        let store = RecordingStore(rootURL: rootURL)
        _ = try await AudioImportService(store: store).importFile(at: sourceURL)
        let transcriptStore = TranscriptStore(rootURL: rootURL)
        let model = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore,
            transcriber: SlowRecordingTranscriber()
        )
        await model.reload()

        let task = Task { @MainActor in
            await model.performSelectedTranscription()
        }
        while !model.isTranscribing {
            await Task.yield()
        }
        task.cancel()
        await task.value

        XCTAssertEqual(model.selectedRecording?.processingState, .pending)
        XCTAssertNil(model.transcript)
        XCTAssertNil(model.transcriptErrorMessage)
        let recordingID = try XCTUnwrap(model.selectedRecording?.id)
        let persistedTranscript = try await transcriptStore.read(recordingID: recordingID)
        XCTAssertNil(persistedTranscript)
    }

    @MainActor
    func testRestartRecoversInterruptedProcessingWithoutTranscriptAsFailedAndRetryable() async throws {
        let store = RecordingStore(rootURL: rootURL)
        var recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        recording.processingState = .processing
        try await store.update(recording)

        let restartedStore = RecordingStore(rootURL: rootURL)
        let model = LibraryViewModel(
            store: restartedStore,
            transcriptStore: TranscriptStore(rootURL: rootURL),
            transcriber: StubRecordingTranscriber(shouldFail: false)
        )
        await model.reload()

        XCTAssertEqual(model.selectedRecording?.processingState, .failed)
        let persisted = try await restartedStore.read(id: recording.id)
        XCTAssertEqual(persisted.processingState, .failed)
        let asset = try XCTUnwrap(persisted.audioAssets.first)
        _ = try await restartedStore.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
    }

    @MainActor
    func testRestartCompletesProcessingWhenTranscriptWasAtomicallySavedBeforeInterruption() async throws {
        let store = RecordingStore(rootURL: rootURL)
        var recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        recording.processingState = .processing
        try await store.update(recording)

        let transcript = try await StubRecordingTranscriber(shouldFail: false).transcribe(
            recording: recording,
            store: store,
            progress: { _ in }
        )
        try await TranscriptStore(rootURL: rootURL).save(transcript)

        let restartedStore = RecordingStore(rootURL: rootURL)
        let model = LibraryViewModel(
            store: restartedStore,
            transcriptStore: TranscriptStore(rootURL: rootURL),
            transcriber: StubRecordingTranscriber(shouldFail: true)
        )
        await model.reload()

        XCTAssertEqual(model.selectedRecording?.processingState, .completed)
        XCTAssertEqual(model.transcript?.text, "Phase five works.")
        let persisted = try await restartedStore.read(id: recording.id)
        XCTAssertEqual(persisted.processingState, .completed)
    }

    @MainActor
    func testInterruptedTranscriptResidueIsPreservedAndSurfacedWithoutBreakingLibrary() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        let residue = rootURL
            .appendingPathComponent(recording.id.uuidString, isDirectory: true)
            .appendingPathComponent(".transcript-crash.tmp")
        try Data("partial transcript".utf8).write(to: residue)

        let model = LibraryViewModel(
            store: RecordingStore(rootURL: rootURL),
            transcriptStore: TranscriptStore(rootURL: rootURL),
            transcriber: StubRecordingTranscriber(shouldFail: false)
        )
        await model.reload()

        XCTAssertEqual(model.selectedRecording?.id, recording.id)
        XCTAssertNil(model.transcript)
        XCTAssertTrue(model.transcriptErrorMessage?.contains("interrupted transcription") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: residue.path))
    }
}
