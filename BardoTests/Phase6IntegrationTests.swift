import Foundation
import XCTest
@testable import Bardo

private enum StubDiarizationError: Error, LocalizedError, Sendable {
    case deliberate

    var errorDescription: String? { "Deliberate diarization failure" }
}

private struct StubRecordingDiarizer: RecordingDiarizing {
    let shouldFail: Bool

    func diarize(
        recording: Recording,
        transcript: Transcript,
        store: RecordingStore,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> Transcript {
        progress(.init(stage: .diarizing, fractionCompleted: 0.5))
        if shouldFail { throw StubDiarizationError.deliberate }
        let updated = try TranscriptSpeakerAligner.applying(
            intervals: [
                DiarizationInterval(speakerIndex: 4, startTime: 0, endTime: 0.55),
                DiarizationInterval(speakerIndex: 9, startTime: 0.55, endTime: 2)
            ],
            to: transcript,
            metadata: DiarizationMetadata(
                engine: "SpeakerKit-Test",
                engineVersion: "1",
                modelID: "fixture",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        progress(.init(stage: .diarizing, fractionCompleted: 1))
        return updated
    }
}

private struct SlowRecordingDiarizer: RecordingDiarizing {
    func diarize(
        recording: Recording,
        transcript: Transcript,
        store: RecordingStore,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> Transcript {
        progress(.init(stage: .diarizing, fractionCompleted: 0.1))
        try await Task.sleep(for: .seconds(30))
        return transcript
    }
}

final class Phase6IntegrationTests: XCTestCase {
    private var rootURL: URL!
    private var sourceURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoPhase6Source-\(UUID().uuidString).wav")
        try AudioTestFixture.makeWAV(at: sourceURL, sampleRate: 16_000, duration: 2)
    }

    override func tearDownWithError() throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        if let sourceURL { try? FileManager.default.removeItem(at: sourceURL) }
        rootURL = nil
        sourceURL = nil
    }

    @MainActor
    func testDiarizationPersistsSpeakerAssignmentsAcrossFreshLibraryReload() async throws {
        let store = RecordingStore(rootURL: rootURL)
        var recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        recording.processingState = .completed
        try await store.update(recording)

        let transcriptStore = TranscriptStore(rootURL: rootURL)
        let rawTranscript = makeRawTranscript(recordingID: recording.id)
        try await transcriptStore.save(rawTranscript)

        let model = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore,
            diarizer: StubRecordingDiarizer(shouldFail: false)
        )
        await model.reload()
        await model.performSelectedDiarization()

        XCTAssertEqual(model.selectedRecording?.processingState, .completed)
        XCTAssertEqual(model.transcript?.speakers.count, 2)
        XCTAssertEqual(model.transcript?.diarizationMetadata?.engine, "SpeakerKit-Test")
        XCTAssertNil(model.diarizationErrorMessage)
        XCTAssertEqual(model.transcript?.text, rawTranscript.text)

        let restarted = LibraryViewModel(
            store: RecordingStore(rootURL: rootURL),
            transcriptStore: TranscriptStore(rootURL: rootURL),
            diarizer: StubRecordingDiarizer(shouldFail: true)
        )
        await restarted.reload()

        XCTAssertEqual(restarted.transcript?.speakers.count, 2)
        XCTAssertEqual(restarted.transcript?.diarizationMetadata?.modelID, "fixture")
        XCTAssertEqual(restarted.transcript?.text, rawTranscript.text)
        XCTAssertEqual(restarted.selectedRecording?.processingState, .completed)
    }

    @MainActor
    func testDiarizationFailurePreservesRawTranscriptAndRecordingState() async throws {
        let store = RecordingStore(rootURL: rootURL)
        var recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        recording.processingState = .completed
        try await store.update(recording)

        let transcriptStore = TranscriptStore(rootURL: rootURL)
        let rawTranscript = makeRawTranscript(recordingID: recording.id)
        try await transcriptStore.save(rawTranscript)

        let model = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore,
            diarizer: StubRecordingDiarizer(shouldFail: true)
        )
        await model.reload()
        await model.performSelectedDiarization()

        XCTAssertNotNil(model.diarizationErrorMessage)
        XCTAssertEqual(model.transcript, rawTranscript)
        XCTAssertEqual(model.selectedRecording?.processingState, .completed)

        let persistedTranscript = try await transcriptStore.read(recordingID: recording.id)
        XCTAssertEqual(persistedTranscript, rawTranscript)
        let persistedRecording = try await store.read(id: recording.id)
        XCTAssertEqual(persistedRecording.processingState, .completed)
    }

    @MainActor
    func testFailedRediarizationPreservesPreviouslyValidSpeakerLabels() async throws {
        let store = RecordingStore(rootURL: rootURL)
        var recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        recording.processingState = .completed
        try await store.update(recording)

        let transcriptStore = TranscriptStore(rootURL: rootURL)
        let rawTranscript = makeRawTranscript(recordingID: recording.id)
        let diarized = try await StubRecordingDiarizer(shouldFail: false).diarize(
            recording: recording,
            transcript: rawTranscript,
            store: store,
            progress: { _ in }
        )
        try await transcriptStore.save(diarized)

        let model = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore,
            diarizer: StubRecordingDiarizer(shouldFail: true)
        )
        await model.reload()
        await model.performSelectedDiarization()

        XCTAssertNotNil(model.diarizationErrorMessage)
        XCTAssertEqual(model.transcript, diarized)
        let persisted = try await transcriptStore.read(recordingID: recording.id)
        XCTAssertEqual(persisted, diarized)
    }

    @MainActor
    func testCancellationDoesNotPublishPartialSpeakerState() async throws {
        let store = RecordingStore(rootURL: rootURL)
        var recording = try await AudioImportService(store: store).importFile(at: sourceURL)
        recording.processingState = .completed
        try await store.update(recording)

        let transcriptStore = TranscriptStore(rootURL: rootURL)
        let rawTranscript = makeRawTranscript(recordingID: recording.id)
        try await transcriptStore.save(rawTranscript)

        let model = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore,
            diarizer: SlowRecordingDiarizer()
        )
        await model.reload()

        let task = Task { @MainActor in
            await model.performSelectedDiarization()
        }
        while !model.isDiarizing {
            await Task.yield()
        }
        task.cancel()
        await task.value

        XCTAssertFalse(model.isDiarizing)
        XCTAssertNil(model.diarizationErrorMessage)
        XCTAssertEqual(model.transcript, rawTranscript)
        let persisted = try await transcriptStore.read(recordingID: recording.id)
        XCTAssertEqual(persisted, rawTranscript)
        let persistedRecording = try await store.read(id: recording.id)
        XCTAssertEqual(persistedRecording.processingState, .completed)
    }

    private func makeRawTranscript(recordingID: Recording.ID) -> Transcript {
        Transcript(
            recordingID: recordingID,
            languageCode: "en",
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 0.5,
                    text: "Hello.",
                    words: [TranscriptWord(startTime: 0, endTime: 0.5, text: "Hello.")]
                ),
                TranscriptSegment(
                    startTime: 0.6,
                    endTime: 1.5,
                    text: "Hi there.",
                    words: [TranscriptWord(startTime: 0.6, endTime: 1.5, text: "Hi there.")]
                )
            ],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "1.0.0",
                modelID: "fixture",
                createdAt: Date(timeIntervalSince1970: 1_600_000_000)
            )
        )
    }
}
