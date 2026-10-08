import Foundation
import XCTest
@testable import Bardo

/// Library behaviors that depend on the order of asynchronous events.
@MainActor
final class LibraryConcurrencyTests: XCTestCase {
    private var rootURL: URL!
    private var sourcesURL: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoLibraryConcurrency-\(UUID().uuidString)", isDirectory: true)
        rootURL = base.appendingPathComponent("Library", isDirectory: true)
        sourcesURL = base.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent()) }
    }

    func testTwoStartsInTheSameTurnRunOneTranscription() async throws {
        let gate = TranscriptionGate()
        let model = try await makeModel(transcriber: GatedTranscriber(gate: gate))

        model.beginTranscription()
        model.beginTranscription()
        XCTAssertTrue(model.isTranscribing, "Starting must be visible immediately")

        await gate.waitForCalls(1)
        await gate.release()
        await waitUntil { !model.isTranscribing }

        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.selectedRecording?.processingState, .completed)
    }

    func testRenamingDuringTranscriptionKeepsBothChanges() async throws {
        let gate = TranscriptionGate()
        let store = RecordingStore(rootURL: rootURL)
        let model = try await makeModel(store: store, transcriber: GatedTranscriber(gate: gate))
        let recordingID = try XCTUnwrap(model.selection)

        model.beginTranscription()
        await gate.waitForCalls(1)
        await model.renameRecording(recordingID, to: "Entrevista con Ana")
        XCTAssertNil(model.recordingActionErrorMessage)
        await gate.release()
        await waitUntil { !model.isTranscribing }

        let persisted = try await store.read(id: recordingID)
        XCTAssertEqual(persisted.title, "Entrevista con Ana")
        XCTAssertEqual(persisted.processingState, .completed)
    }

    func testTranscriptionExplainsWhyAnotherRecordingMustWait() async throws {
        let gate = TranscriptionGate()
        let model = try await makeModel(transcriber: GatedTranscriber(gate: gate), recordingCount: 2)
        let first = try XCTUnwrap(model.recordings.first?.id)
        let second = try XCTUnwrap(model.recordings.last?.id)
        model.selection = first

        model.beginTranscription()
        await gate.waitForCalls(1)

        XCTAssertNil(model.transcriptionBlocker(for: first))
        XCTAssertNotNil(model.transcriptionBlocker(for: second))
        XCTAssertTrue(model.isProcessing(first))
        XCTAssertFalse(model.isProcessing(second))

        await gate.release()
        await waitUntil { !model.isTranscribing }
        XCTAssertNil(model.transcriptionBlocker(for: second))
    }

    func testEditsDuringSpeakerIdentificationAreRefusedWithAnExplanation() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let transcriptStore = TranscriptStore(rootURL: rootURL)
        let gate = TranscriptionGate()
        let model = try await makeModel(
            store: store,
            transcriptStore: transcriptStore,
            diarizer: GatedDiarizer(gate: gate)
        )
        let recordingID = try XCTUnwrap(model.selection)
        let segment = TranscriptSegment(startTime: 0, endTime: 1, text: "Texto original")
        try await transcriptStore.save(Transcript(
            recordingID: recordingID,
            segments: [segment],
            metadata: TranscriptMetadata(engine: "fixture", engineVersion: "1", modelID: "fixture")
        ))
        await model.loadTranscriptForSelection()

        model.beginDiarization()
        await gate.waitForCalls(1)
        await model.updateTranscriptSegment(segment.id, text: "Texto corregido")

        XCTAssertNotNil(model.transcriptEditErrorMessage)
        let duringDiarization = try await transcriptStore.read(recordingID: recordingID)
        XCTAssertNil(duringDiarization?.segments.first?.editedText)

        await gate.release()
        await waitUntil { !model.isDiarizing }
        await model.updateTranscriptSegment(segment.id, text: "Texto corregido")
        let afterDiarization = try await transcriptStore.read(recordingID: recordingID)
        XCTAssertEqual(afterDiarization?.segments.first?.displayText, "Texto corregido")
    }

    func testReloadingTheLibraryKeepsThePlaybackPosition() async throws {
        let model = try await makeModel()
        await model.preparePlaybackForSelection()
        XCTAssertTrue(model.playback.isLoaded)
        model.playback.seek(to: 0.3)

        await model.reload()

        XCTAssertTrue(model.playback.isLoaded)
        XCTAssertEqual(model.playback.position, 0.3, accuracy: 0.01, "An unrelated reload must not reset playback")
    }

    // MARK: - Helpers

    private func makeModel(
        store: RecordingStore? = nil,
        transcriptStore: TranscriptStore? = nil,
        transcriber: (any RecordingTranscribing)? = nil,
        diarizer: (any RecordingDiarizing)? = nil,
        recordingCount: Int = 1
    ) async throws -> LibraryViewModel {
        let store = store ?? RecordingStore(rootURL: rootURL)
        let importer = AudioImportService(store: store)
        for index in 0..<recordingCount {
            let source = sourcesURL.appendingPathComponent("source-\(index).wav")
            try AudioTestFixture.makeWAV(at: source, duration: 1)
            _ = try await importer.importFile(at: source)
        }
        let model = LibraryViewModel(
            store: store,
            transcriptStore: transcriptStore ?? TranscriptStore(rootURL: rootURL),
            transcriber: transcriber,
            diarizer: diarizer
        )
        await model.reload()
        return model
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous state.", file: file, line: line)
    }
}

/// Holds model work until the test releases it.
private actor TranscriptionGate {
    private(set) var calls = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        calls += 1
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<300 where calls < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct GatedTranscriber: RecordingTranscribing {
    let gate: TranscriptionGate

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        await gate.enter()
        return Transcript(
            recordingID: recording.id,
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Hola.")],
            metadata: TranscriptMetadata(engine: "fixture", engineVersion: "1", modelID: "fixture")
        )
    }
}

private struct GatedDiarizer: RecordingDiarizing {
    let gate: TranscriptionGate

    func diarize(
        recording: Recording,
        transcript: Transcript,
        store: RecordingStore,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> Transcript {
        await gate.enter()
        return try TranscriptSpeakerAligner.applying(
            intervals: [DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 1)],
            to: transcript,
            metadata: DiarizationMetadata(engine: "fixture", engineVersion: "1", modelID: "fixture")
        )
    }
}
