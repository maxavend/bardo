import Foundation
import XCTest
@testable import Bardo

private enum LifecycleFixtureError: Error, LocalizedError, Sendable {
    case failed

    var errorDescription: String? { "Lifecycle fixture failed." }
}

private struct LifecycleTranscriber: RecordingTranscribing {
    enum Result: Sendable {
        case success
        case failure
        case waitForCancellation
    }

    let result: Result

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        progress(.init(stage: .transcribing, fractionCompleted: 0.5))
        switch result {
        case .success:
            return Transcript(
                recordingID: recording.id,
                segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "A completed transcript.")],
                metadata: TranscriptMetadata(engine: "fixture", engineVersion: "1", modelID: "fixture")
            )
        case .failure:
            throw LifecycleFixtureError.failed
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(30))
            return Transcript(
                recordingID: recording.id,
                segments: [],
                metadata: TranscriptMetadata(engine: "fixture", engineVersion: "1", modelID: "fixture")
            )
        }
    }
}

private struct LifecycleMinutesGenerator: MeetingMinutesGenerating {
    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MeetingMinutes {
        progress(1)
        return MeetingMinutes(
            recordingID: input.transcript.recordingID,
            sourceTranscriptMetadata: input.transcript.metadata,
            modelID: "fixture-minutes",
            text: "## Decisions\n- Only transcript text was provided.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func reset() async {}
}

private struct LifecycleDiarizer: RecordingDiarizing {
    func diarize(
        recording: Recording,
        transcript: Transcript,
        store: RecordingStore,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> Transcript {
        progress(.init(stage: .diarizing, fractionCompleted: 1))
        return try TranscriptSpeakerAligner.applying(
            intervals: [
                DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 0.5),
                DiarizationInterval(speakerIndex: 1, startTime: 0.5, endTime: 1)
            ],
            to: transcript,
            metadata: DiarizationMetadata(
                engine: "fixture",
                engineVersion: "1",
                modelID: "fixture"
            )
        )
    }
}

final class ModelTaskLifecycleTests: XCTestCase {
    @MainActor
    func testTranscriptionTaskReferenceClearsAfterSuccess() async throws {
        let (model, _) = try await makeModel(transcriber: LifecycleTranscriber(result: .success))

        model.beginTranscription()
        await waitUntil { model.isTranscribing }
        await waitUntil { !model.isTranscribing }

        XCTAssertFalse(model.hasActiveTranscriptionTask)
        XCTAssertNil(model.transcriptErrorMessage)
        XCTAssertEqual(model.selectedRecording?.processingState, .completed)
    }

    @MainActor
    func testTranscriptionTaskReferenceClearsAfterFailureAndPublishesError() async throws {
        let (model, _) = try await makeModel(transcriber: LifecycleTranscriber(result: .failure))

        model.beginTranscription()
        await waitUntil { model.isTranscribing }
        await waitUntil { !model.isTranscribing }

        XCTAssertFalse(model.hasActiveTranscriptionTask)
        XCTAssertEqual(model.transcriptErrorMessage, LifecycleFixtureError.failed.localizedDescription)
        XCTAssertEqual(model.selectedRecording?.processingState, .failed)
    }

    @MainActor
    func testTranscriptionTaskReferenceClearsAfterCancellationWithoutError() async throws {
        let (model, _) = try await makeModel(transcriber: LifecycleTranscriber(result: .waitForCancellation))

        model.beginTranscription()
        await waitUntil { model.isTranscribing }
        model.cancelTranscription()
        await waitUntil { !model.isTranscribing }

        XCTAssertFalse(model.hasActiveTranscriptionTask)
        XCTAssertNil(model.transcriptErrorMessage)
        XCTAssertEqual(model.selectedRecording?.processingState, .pending)
    }

    @MainActor
    func testMeetingMinutesStartsOnlyForCompletedTranscriptAndOwnsTask() async throws {
        let (model, transcriptStore) = try await makeModel(
            transcriber: LifecycleTranscriber(result: .success),
            minutesGenerator: LifecycleMinutesGenerator()
        )

        XCTAssertFalse(model.canGenerateMeetingMinutes)
        model.beginMeetingMinutes()
        XCTAssertFalse(model.hasActiveMeetingMinutesTask)

        let transcript = Transcript(
            recordingID: try XCTUnwrap(model.selection),
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "A completed transcript.")],
            metadata: TranscriptMetadata(engine: "fixture", engineVersion: "1", modelID: "fixture")
        )
        try await transcriptStore.save(transcript)
        await model.loadTranscriptForSelection()

        XCTAssertTrue(model.canGenerateMeetingMinutes)
        model.beginMeetingMinutes()
        await waitUntil { model.hasActiveMeetingMinutesTask }
        await waitUntil { !model.isGeneratingMeetingMinutes }

        XCTAssertFalse(model.hasActiveMeetingMinutesTask)
        XCTAssertEqual(model.meetingMinutes?.text, "## Decisions\n- Only transcript text was provided.")
        XCTAssertNil(model.meetingMinutesErrorMessage)
    }

    @MainActor
    func testSuccessfulDiarizationRequestsNamingOnlyForMultipleSpeakers() async throws {
        let (model, transcriptStore) = try await makeModel(
            transcriber: LifecycleTranscriber(result: .success),
            diarizer: LifecycleDiarizer()
        )
        let transcript = Transcript(
            recordingID: try XCTUnwrap(model.selection),
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Two people.")],
            metadata: TranscriptMetadata(engine: "fixture", engineVersion: "1", modelID: "fixture")
        )
        try await transcriptStore.save(transcript)
        await model.loadTranscriptForSelection()

        model.beginDiarization()
        await waitUntil { model.hasActiveDiarizationTask }
        await waitUntil { model.isDiarizing }
        await waitUntil { !model.isDiarizing }

        XCTAssertTrue(model.shouldOpenNamingFlow())
        XCTAssertTrue(model.shouldPresentSpeakerNamingSheet)
        XCTAssertFalse(model.hasActiveDiarizationTask)
        model.consumeSpeakerNamingSheetRequest()
        XCTAssertFalse(model.shouldPresentSpeakerNamingSheet)
    }

    @MainActor
    private func makeModel(
        transcriber: any RecordingTranscribing,
        minutesGenerator: (any MeetingMinutesGenerating)? = nil,
        diarizer: (any RecordingDiarizing)? = nil
    ) async throws -> (LibraryViewModel, TranscriptStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoTaskLifecycle-\(UUID().uuidString)", isDirectory: true)
        let store = RecordingStore(rootURL: root)
        let recording = Recording(
            id: UUID(),
            title: "Lifecycle fixture",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1,
            sources: [.importedFile],
            processingState: .pending,
            audioAssets: []
        )
        try await store.save(recording)
        let transcriptStore = TranscriptStore(rootURL: root)
        let model = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore,
            transcriber: transcriber,
            diarizer: diarizer,
            meetingMinutesGenerator: minutesGenerator
        )
        await model.reload()
        return (model, transcriptStore)
    }

    @MainActor
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for lifecycle state.", file: file, line: line)
    }
}
