import Foundation
import XCTest
@testable import Bardo

/// Builds the portfolio sample Library from `tools/portfolio`: conversations synthesized
/// with macOS voices, published as Bardo would publish them and transcribed with the real
/// models. Opt-in:
///
///     TEST_RUNNER_BARDO_DESIGN_SEED_HOME=<empty folder>
///     TEST_RUNNER_BARDO_E2E_MODELS_ROOT=<copy of installed models>
///     TEST_RUNNER_BARDO_PORTFOLIO_SCRIPT=tools/portfolio/conversations.json
///     TEST_RUNNER_BARDO_PORTFOLIO_AUDIO=<output of generate_audio.py>
///
/// Speakers SpeakerKit finds are named after the persona whose script turns they overlap
/// most. The recording IDs to mark as favorites are written to `<home>/favorites.txt`.
final class PortfolioSeedTests: XCTestCase {
    private struct Script: Decodable {
        struct Conversation: Decodable {
            let id: String
            let title: String
            let createdAt: Date
            let kind: String
            let fileName: String?
            let state: ProcessingState
            let diarize: Bool
            let favorite: Bool?
            let names: [String: String]?
        }
        let conversations: [Conversation]
    }

    private struct Timeline: Decodable {
        struct Turn: Decodable {
            let persona: String
            let text: String
            let start: TimeInterval
            let end: TimeInterval
        }
        let files: [String: String]
        let turns: [Turn]
    }

    func testSeedPortfolioLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let homePath = environment["BARDO_DESIGN_SEED_HOME"],
              let modelsPath = environment["BARDO_E2E_MODELS_ROOT"],
              let scriptPath = environment["BARDO_PORTFOLIO_SCRIPT"],
              let audioPath = environment["BARDO_PORTFOLIO_AUDIO"] else {
            throw XCTSkip("Set BARDO_DESIGN_SEED_HOME, BARDO_E2E_MODELS_ROOT, BARDO_PORTFOLIO_SCRIPT and BARDO_PORTFOLIO_AUDIO.")
        }

        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let libraryURL = home.appendingPathComponent("Library/Application Support/Bardo/Library", isDirectory: true)
        let store = RecordingStore(rootURL: libraryURL)
        let transcripts = TranscriptStore(rootURL: libraryURL)
        let modelStore = BardoModelStore(rootURL: URL(fileURLWithPath: modelsPath, isDirectory: true))
        let transcriber = WhisperTranscriptionService(
            modelManager: TranscriptionModelManager(downloadRoot: modelStore.root(for: .whisperTurbo))
        )
        let diarizer = SpeakerDiarizationService(modelStore: modelStore, operations: .live)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let script = try decoder.decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: scriptPath)))
        var favorites: [String] = []

        for conversation in script.conversations {
            let folder = URL(fileURLWithPath: audioPath, isDirectory: true).appendingPathComponent(conversation.id)
            let timeline = try JSONDecoder().decode(
                Timeline.self,
                from: Data(contentsOf: folder.appendingPathComponent("timeline.json"))
            )

            var assets: [AudioAsset] = []
            var files: [AudioAsset.ID: URL] = [:]
            func add(_ key: String, name: String, role: AudioAssetRole, derivedFrom: [UUID] = []) throws -> AudioAsset {
                let url = folder.appendingPathComponent(timeline.files[key]!)
                let asset = AudioAsset(
                    originalFileName: name,
                    fileExtension: url.pathExtension,
                    metadata: try AudioMetadataReader().read(from: url),
                    role: role,
                    derivedFromAssetIDs: derivedFrom
                )
                assets.append(asset)
                files[asset.id] = url
                return asset
            }

            let sources: Set<AudioSource>
            switch conversation.kind {
            case "meeting":
                let system = try add("system", name: "System Audio.m4a", role: .systemOriginal)
                let microphone = try add("microphone", name: "Microphone.m4a", role: .microphoneOriginal)
                _ = try add("mix", name: "Conversation Mix.m4a", role: .conversationMix, derivedFrom: [system.id, microphone.id])
                sources = [.systemAudio, .microphone]
            case "microphone":
                _ = try add("microphone", name: "Nueva grabación.m4a", role: .microphoneOriginal)
                sources = [.microphone]
            case "system":
                _ = try add("system", name: "System Audio.m4a", role: .systemOriginal)
                sources = [.systemAudio]
            default:
                _ = try add("imported", name: conversation.fileName ?? "Audio.m4a", role: .importedOriginal)
                sources = [.importedFile]
            }

            let duration = assets.map(\.metadata.duration).max()
            let transcribes = conversation.state == .completed
            let recording = Recording(
                title: conversation.title,
                createdAt: conversation.createdAt,
                duration: duration,
                sources: sources,
                processingState: transcribes ? .processing : conversation.state,
                audioAssets: assets
            )
            try await store.importRecording(recording, audioFiles: files)
            if conversation.favorite == true { favorites.append(recording.id.uuidString) }
            guard transcribes else { continue }

            var transcript = try await transcriber.transcribe(
                recording: recording,
                store: store,
                trackMode: .perTrack,
                progress: { _ in },
                liveUpdate: { _ in }
            )
            if conversation.diarize {
                transcript = try await diarizer.diarize(recording: recording, transcript: transcript, store: store) { _ in }
                name(&transcript, after: timeline, names: conversation.names ?? [:])
            }
            try await transcripts.save(transcript)

            var completed = recording
            completed.processingState = .completed
            try await store.update(completed)

            print("PORTFOLIO \(conversation.id): \(transcript.segments.count) segments, \(transcript.speakers.count) speakers")
            for segment in transcript.segments {
                let speaker = transcript.speakers.first { $0.id == segment.speakerID }
                let label = speaker?.name ?? speaker?.role?.rawValue ?? "—"
                print(String(format: "  [%5.1f] %@: %@", segment.startTime, label, segment.displayText))
            }
        }

        try favorites.joined(separator: "\n").write(
            to: home.appendingPathComponent("favorites.txt"), atomically: true, encoding: .utf8
        )
        let snapshot = try await store.loadLibrary()
        XCTAssertEqual(snapshot.recordings.count, script.conversations.count)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    /// Names each speaker after the persona it overlaps most in the script. The person
    /// recording (`tu`) keeps Bardo's own "You" label on per-track transcripts.
    private func name(_ transcript: inout Transcript, after timeline: Timeline, names: [String: String]) {
        for index in transcript.speakers.indices where transcript.speakers[index].role != .localUser {
            let id = transcript.speakers[index].id
            var overlap: [String: TimeInterval] = [:]
            for segment in transcript.segments where segment.speakerID == id {
                for turn in timeline.turns {
                    let shared = min(segment.endTime, turn.end) - max(segment.startTime, turn.start)
                    if shared > 0 { overlap[turn.persona, default: 0] += shared }
                }
            }
            if let persona = overlap.max(by: { $0.value < $1.value })?.key, let name = names[persona] {
                transcript.speakers[index].name = name
            }
        }
    }
}
