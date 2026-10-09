import Foundation
import XCTest
@testable import Bardo

/// Builds a realistic sample Library for design reviews (see `DesignReview`). Opt-in:
///
///     TEST_RUNNER_BARDO_DESIGN_SEED_HOME=<empty folder>
///     TEST_RUNNER_BARDO_E2E_MODELS_ROOT=<copy of installed models>
///     TEST_RUNNER_BARDO_E2E_AUDIO=<short dialogue>  TEST_RUNNER_BARDO_E2E_LONG_AUDIO=<long dialogue>
///
/// The Library is written under `<home>/Library/Application Support/Bardo/Library`, the
/// layout Bardo uses when launched with `CFFIXED_USER_HOME=<home>`.
final class DesignSeedTests: XCTestCase {
    func testSeedDesignReviewLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let homePath = environment["BARDO_DESIGN_SEED_HOME"],
              let modelsPath = environment["BARDO_E2E_MODELS_ROOT"],
              let dialoguePath = environment["BARDO_E2E_AUDIO"],
              let longDialoguePath = environment["BARDO_E2E_LONG_AUDIO"] else {
            throw XCTSkip("Set BARDO_DESIGN_SEED_HOME, BARDO_E2E_MODELS_ROOT, BARDO_E2E_AUDIO and BARDO_E2E_LONG_AUDIO.")
        }

        let support = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Bardo", isDirectory: true)
        let libraryURL = support.appendingPathComponent("Library", isDirectory: true)
        let store = RecordingStore(rootURL: libraryURL)
        let transcripts = TranscriptStore(rootURL: libraryURL)
        let modelStore = BardoModelStore(rootURL: URL(fileURLWithPath: modelsPath, isDirectory: true))
        let transcriber = WhisperTranscriptionService(
            modelManager: TranscriptionModelManager(downloadRoot: modelStore.root(for: .whisperTurbo))
        )
        let diarizer = SpeakerDiarizationService(modelStore: modelStore, operations: .live)
        let dialogue = URL(fileURLWithPath: dialoguePath)
        let longDialogue = URL(fileURLWithPath: longDialoguePath)
        let now = Date()

        func publish(
            _ title: String,
            daysAgo: Double,
            audio: URL,
            sources: Set<AudioSource>,
            role: AudioAssetRole,
            state: ProcessingState
        ) async throws -> Recording {
            let metadata = try AudioMetadataReader().read(from: audio)
            let asset = AudioAsset(
                originalFileName: audio.lastPathComponent,
                fileExtension: audio.pathExtension,
                metadata: metadata,
                role: role
            )
            let recording = Recording(
                title: title,
                createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                duration: metadata.duration,
                sources: sources,
                processingState: state,
                audioAssets: [asset]
            )
            try await store.importRecording(recording, audioAsset: asset, from: audio)
            return recording
        }

        // A named, edited, two-speaker design meeting.
        let weekly = try await publish("Revisión semanal de diseño", daysAgo: 0.1, audio: dialogue,
                                       sources: [.microphone], role: .microphoneOriginal, state: .completed)
        var weeklyTranscript = try await transcriber.transcribe(recording: weekly, store: store) { _ in }
        weeklyTranscript = try await diarizer.diarize(recording: weekly, transcript: weeklyTranscript, store: store) { _ in }
        if weeklyTranscript.speakers.count >= 2 {
            weeklyTranscript.speakers[0].name = "Paulina"
            weeklyTranscript.speakers[1].name = "Mónica"
        }
        if let index = weeklyTranscript.segments.indices.last {
            weeklyTranscript.segments[index].editedText = weeklyTranscript.segments[index].text
                .replacingOccurrences(of: "viernes", with: "viernes 14")
        }
        try await transcripts.save(weeklyTranscript)

        // A longer call with unnamed speakers.
        let planning = try await publish("Llamada de planificación del sprint", daysAgo: 1.3, audio: longDialogue,
                                         sources: [.systemAudio], role: .systemOriginal, state: .completed)
        var planningTranscript = try await transcriber.transcribe(recording: planning, store: store) { _ in }
        planningTranscript = try await diarizer.diarize(recording: planning, transcript: planningTranscript, store: store) { _ in }
        try await transcripts.save(planningTranscript)

        // An imported interview, transcribed but without speakers.
        let interview = try await publish("Entrevista con Andrea", daysAgo: 3.6, audio: dialogue,
                                          sources: [.importedFile], role: .importedOriginal, state: .completed)
        try await transcripts.save(try await transcriber.transcribe(recording: interview, store: store) { _ in })

        // Not transcribed yet, and a failed attempt.
        _ = try await publish("Nota de voz", daysAgo: 6.2, audio: dialogue,
                              sources: [.microphone], role: .microphoneOriginal, state: .pending)
        _ = try await publish("Demo para cliente", daysAgo: 9.4, audio: longDialogue,
                              sources: [.systemAudio], role: .systemOriginal, state: .failed)

        let favorites = [weekly.id.uuidString]
        try JSONSerialization.data(withJSONObject: favorites)
            .write(to: support.appendingPathComponent("design-favorites.json"))

        let snapshot = try await store.loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, 5)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }
}
