import Foundation
import XCTest
@testable import Bardo

/// Runs the real WhisperKit and SpeakerKit pipelines on real audio. CI has no models,
/// so this is opt-in:
///
///     TEST_RUNNER_BARDO_E2E_MODELS_ROOT=<folder with whisper-turbo and speaker-kit> \
///     TEST_RUNNER_BARDO_E2E_AUDIO=<speech recording> \
///     xcodebuild test -only-testing:BardoTests/RealModelEndToEndTests ...
///
/// Point the models root at a copy (for example `cp -cR`), never at the live Library.
final class RealModelEndToEndTests: XCTestCase {
    func testRealTranscriptionAndSpeakerIdentification() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelsPath = environment["BARDO_E2E_MODELS_ROOT"],
              let audioPath = environment["BARDO_E2E_AUDIO"] else {
            throw XCTSkip("Set BARDO_E2E_MODELS_ROOT and BARDO_E2E_AUDIO to run the real-model check.")
        }

        let workspace = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BardoRealModels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let libraryURL = workspace.appendingPathComponent("Library", isDirectory: true)
        let store = RecordingStore(rootURL: libraryURL)
        let transcriptStore = TranscriptStore(rootURL: libraryURL)
        let modelStore = BardoModelStore(rootURL: URL(fileURLWithPath: modelsPath, isDirectory: true))

        let recording = try await AudioImportService(store: store).importFile(at: URL(fileURLWithPath: audioPath))

        let transcriber = WhisperTranscriptionService(
            modelManager: TranscriptionModelManager(downloadRoot: modelStore.root(for: .whisperTurbo))
        )
        let transcriptionStart = ContinuousClock.now
        let transcript = try await transcriber.transcribe(recording: recording, store: store) { _ in }
        let transcriptionTime = ContinuousClock.now - transcriptionStart
        try await transcriptStore.save(transcript)

        let text = transcript.text.lowercased()
        print("E2E transcript (\(transcriptionTime)): \(transcript.text)")
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertEqual(transcript.languageCode, "es")
        for expected in ["reunión", "prototipo", "biblioteca", "viernes"] {
            XCTAssertTrue(text.contains(expected), "Missing \"\(expected)\" in: \(transcript.text)")
        }
        XCTAssertTrue(transcript.segments.allSatisfy { !$0.words.isEmpty }, "Word timestamps are required for seeking")

        let diarizer = SpeakerDiarizationService(modelStore: modelStore, operations: .live)
        let installed = await diarizer.hasInstalledModels()
        XCTAssertTrue(installed, "The copied SpeakerKit cache must be recognized")
        let diarizationStart = ContinuousClock.now
        let diarized = try await diarizer.diarize(
            recording: recording,
            transcript: transcript,
            store: store
        ) { _ in }
        let diarizationTime = ContinuousClock.now - diarizationStart
        try await transcriptStore.save(diarized)

        print("E2E speakers (\(diarizationTime)): \(diarized.speakers.count)")
        for segment in diarized.segments {
            let index = diarized.speakers.firstIndex { $0.id == segment.speakerID }.map { $0 + 1 } ?? 0
            print(String(format: "  [%5.1f–%5.1f] S%d %@", segment.startTime, segment.endTime, index, segment.displayText))
        }
        XCTAssertGreaterThanOrEqual(diarized.speakers.count, 2, "Two different voices should be told apart")
        XCTAssertTrue(diarized.segments.contains { $0.speakerID != nil })

        let reloaded = try await transcriptStore.read(recordingID: recording.id)
        XCTAssertEqual(reloaded?.speakers.count, diarized.speakers.count)
    }

    /// A recording longer than one incremental loading chunk (120 s), with one keyword
    /// per turn and alternating voices. Verifies nothing is lost or reordered across
    /// chunk boundaries and that speakers alternate.
    func testLongRecordingKeepsEveryTurnInOrder() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelsPath = environment["BARDO_E2E_MODELS_ROOT"],
              let audioPath = environment["BARDO_E2E_LONG_AUDIO"],
              let wordsPath = environment["BARDO_E2E_LONG_WORDS"] else {
            throw XCTSkip("Set BARDO_E2E_MODELS_ROOT, BARDO_E2E_LONG_AUDIO and BARDO_E2E_LONG_WORDS.")
        }
        let keywords = try String(contentsOfFile: wordsPath, encoding: .utf8)
            .split(separator: "\n").map { String($0).lowercased() }

        let workspace = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BardoRealModelsLong-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = RecordingStore(rootURL: workspace.appendingPathComponent("Library", isDirectory: true))
        let modelStore = BardoModelStore(rootURL: URL(fileURLWithPath: modelsPath, isDirectory: true))
        let recording = try await AudioImportService(store: store).importFile(at: URL(fileURLWithPath: audioPath))
        let duration = try XCTUnwrap(recording.duration)

        let transcriber = WhisperTranscriptionService(
            modelManager: TranscriptionModelManager(downloadRoot: modelStore.root(for: .whisperTurbo))
        )
        let start = ContinuousClock.now
        let transcript = try await transcriber.transcribe(recording: recording, store: store) { _ in }
        print("E2E long transcription of \(Int(duration)) s took \(ContinuousClock.now - start)")

        let starts = transcript.segments.map(\.startTime)
        XCTAssertEqual(starts, starts.sorted(), "Segments must stay in time order")
        XCTAssertGreaterThan(transcript.segments.last?.endTime ?? 0, duration - 10, "The end of the recording must be transcribed")

        let text = transcript.text.lowercased()
        var searchStart = text.startIndex
        for keyword in keywords {
            guard let range = text.range(of: keyword, range: searchStart..<text.endIndex) else {
                XCTFail("Missing or out-of-order keyword \"\(keyword)\"")
                continue
            }
            searchStart = range.upperBound
        }

        let diarized = try await SpeakerDiarizationService(modelStore: modelStore, operations: .live)
            .diarize(recording: recording, transcript: transcript, store: store) { _ in }
        print("E2E long speakers: \(diarized.speakers.count), segments: \(diarized.segments.count)")
        XCTAssertEqual(diarized.speakers.count, 2)

        // Each keyword belongs to one turn; consecutive turns alternate voices.
        let keywordSpeakers: [Speaker.ID?] = keywords.map { keyword in
            diarized.segments.first { $0.displayText.lowercased().contains(keyword) }?.speakerID
        }
        let alternations = zip(keywordSpeakers, keywordSpeakers.dropFirst()).filter { $0 != nil && $0 != $1 }.count
        print("E2E long alternations: \(alternations) of \(keywords.count - 1)")
        XCTAssertGreaterThanOrEqual(Double(alternations), Double(keywords.count - 1) * 0.9)
    }
}
