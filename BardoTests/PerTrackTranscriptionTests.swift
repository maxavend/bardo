import Foundation
import XCTest
@testable import Bardo

final class PerTrackTranscriptionTests: XCTestCase {
    // MARK: Merging the tracks

    func testMicrophoneIsYouAndMacAudioIsOthersInTimelineOrder() {
        let system = [segment("Hola, ¿cómo estás?", at: 0, source: .system)]
        let microphone = [segment("Muy bien, gracias", at: 3, source: .microphone)]

        let merged = TrackTranscriptMerger.merge(system: system, microphone: microphone)

        XCTAssertEqual(merged.speakers.map(\.role), [.localUser, .others])
        XCTAssertEqual(merged.segments.map(\.text), ["Hola, ¿cómo estás?", "Muy bien, gracias"])
        XCTAssertEqual(merged.segments.map(\.source), [.system, .microphone])
        XCTAssertEqual(merged.segments[0].speakerID, merged.speakers[1].id)
        XCTAssertEqual(merged.segments[1].speakerID, merged.speakers[0].id)
    }

    func testOverlappingVoicesStaySeparateTurns() {
        let system = [segment("Entonces lo cerramos el viernes", at: 10, source: .system)]
        let microphone = [segment("Perfecto, yo me encargo", at: 10.4, source: .microphone)]

        let merged = TrackTranscriptMerger.merge(system: system, microphone: microphone)

        XCTAssertEqual(merged.segments.count, 2, "Speech at the same time is kept for both people")
    }

    func testMicrophoneEchoOfTheCallIsLeftOut() {
        let system = [segment("Esta es una prueba del audio interno del Mac", at: 4, source: .system)]
        // The speakers play the call and the microphone hears it again 120 ms later.
        let microphone = [segment("Esta es una prueba del audio interno del Mac", at: 4.12, source: .microphone)]

        let merged = TrackTranscriptMerger.merge(system: system, microphone: microphone)

        XCTAssertEqual(merged.segments.map(\.source), [.system])
        XCTAssertEqual(merged.speakers.map(\.role), [.others], "No one is \"You\" when the microphone only heard the call")
    }

    func testOwnWordsThatShareAFewWordsWithTheCallAreKept() {
        let system = [segment("¿Revisaste el prototipo de la aplicación?", at: 20, source: .system)]
        let microphone = [segment("Sí, el prototipo quedó listo ayer en la tarde", at: 22, source: .microphone)]

        XCTAssertFalse(TrackTranscriptMerger.isEcho(microphone[0], of: system))
    }

    func testEchoIsRecognisedWithoutWordTimings() {
        let system = [TranscriptSegment(startTime: 0, endTime: 3, text: "Nos vemos el lunes", source: .system)]
        let echo = TranscriptSegment(startTime: 0.1, endTime: 3.1, text: "nos vemos el lunes", source: .microphone)

        XCTAssertTrue(TrackTranscriptMerger.isEcho(echo, of: system))
    }

    // MARK: Choosing the tracks

    func testDualRecordingTranscribesMacAudioThenMicrophoneWhenAskedPerTrack() {
        let (recording, system, microphone) = dualRecording()

        let tracks = TranscriptionAudioSelection.separateTracks(for: recording, mode: .perTrack)

        XCTAssertEqual(tracks?.system.id, system.id)
        XCTAssertEqual(tracks?.microphone.id, microphone.id)
        XCTAssertNil(TranscriptionAudioSelection.separateTracks(for: recording, mode: .mix))
    }

    func testSingleSourceRecordingNeverSplitsIntoTracks() {
        let asset = AudioAsset(
            originalFileName: "nota.m4a",
            fileExtension: "m4a",
            metadata: AudioMetadata(duration: 30, codec: "AAC", sampleRate: 48_000, channelCount: 1),
            role: .microphoneOriginal
        )
        let recording = Recording(title: "Nota", duration: 30, sources: [.microphone], audioAssets: [asset])

        XCTAssertNil(TranscriptionAudioSelection.separateTracks(for: recording, mode: .perTrack))
    }

    // MARK: Live progress

    func testLiveProgressCountsBothPassesOverTheTimeline() {
        let buffer = TranscriptionLiveBuffer(recordingID: UUID(), audioDuration: 100, passCount: 2)

        _ = buffer.beginPass(0)
        let firstHalf = buffer.merge([segment("uno", at: 98, source: .system)])
        XCTAssertEqual(firstHalf.fractionCompleted, 0.5, accuracy: 0.01)

        _ = buffer.beginPass(1)
        let secondPass = buffer.merge([segment("dos", at: 48, source: .microphone)])
        XCTAssertEqual(secondPass.fractionCompleted, 0.75, accuracy: 0.01)
        XCTAssertEqual(secondPass.segments.count, 2)
    }

    // MARK: Participants

    func testIdentifyingParticipantsOnlyTouchesTheMacAudio() throws {
        let merged = TrackTranscriptMerger.merge(
            system: [
                segment("Hola equipo", at: 0, source: .system),
                segment("Yo presento primero", at: 6, source: .system)
            ],
            microphone: [segment("Buenos días", at: 3, source: .microphone)]
        )
        let transcript = Transcript(
            recordingID: UUID(),
            speakers: merged.speakers,
            segments: merged.segments,
            metadata: TranscriptMetadata(engine: "test", engineVersion: "1", modelID: "m", trackMode: .perTrack)
        )

        let identified = try TranscriptSpeakerAligner.applyingToOthers(
            intervals: [
                DiarizationInterval(speakerIndex: 0, startTime: 0, endTime: 2.5),
                DiarizationInterval(speakerIndex: 1, startTime: 5.5, endTime: 9)
            ],
            to: transcript,
            metadata: DiarizationMetadata(engine: "test", engineVersion: "1", modelID: "d")
        )

        let you = try XCTUnwrap(identified.speakers.first { $0.role == .localUser })
        XCTAssertEqual(identified.speakers.filter { $0.role == nil }.count, 2)
        XCTAssertFalse(identified.speakers.contains { $0.role == .others }, "\"Others\" gives way to the participants found")
        let own = try XCTUnwrap(identified.segments.first { $0.source == .microphone })
        XCTAssertEqual(own.text, "Buenos días")
        XCTAssertEqual(own.speakerID, you.id)
        XCTAssertTrue(identified.segments.filter { $0.source != .microphone }.allSatisfy { $0.source == .system })
        XCTAssertEqual(identified.segments.map(\.startTime), identified.segments.map(\.startTime).sorted())
    }

    func testPerTrackTranscriptStillOffersToIdentifyTheOthers() {
        let merged = TrackTranscriptMerger.merge(
            system: [segment("Hola", at: 0, source: .system)],
            microphone: [segment("Hola", at: 5, source: .microphone)]
        )
        let transcript = Transcript(
            recordingID: UUID(),
            speakers: merged.speakers,
            segments: merged.segments,
            metadata: TranscriptMetadata(engine: "test", engineVersion: "1", modelID: "m", trackMode: .perTrack)
        )

        XCTAssertEqual(SpeakerNamingPolicy.presentation(for: transcript), .identifySpeakers)
    }

    // MARK: Names

    func testSpeakersAreNamedByWhatBardoKnowsUntilSomeoneNamesThem() {
        let you = Speaker(role: .localUser)
        let others = Speaker(role: .others)
        let first = Speaker()
        let second = Speaker(name: "  Paulina ")
        let transcript = Transcript(
            recordingID: UUID(),
            speakers: [you, others, first, second],
            metadata: TranscriptMetadata(engine: "test", engineVersion: "1", modelID: "m")
        )

        XCTAssertEqual(transcript.displayName(for: you, localName: nil), String(localized: "You"))
        XCTAssertEqual(transcript.displayName(for: you, localName: "Max"), "Max")
        XCTAssertEqual(transcript.displayName(for: others), String(localized: "Others"))
        XCTAssertEqual(
            transcript.displayName(for: first),
            String.localizedStringWithFormat(String(localized: "Speaker %lld"), 1),
            "Numbering skips the speakers Bardo already knows"
        )
        XCTAssertEqual(transcript.displayName(for: second), "Paulina")
    }

    // MARK: Compatibility

    func testTranscriptsSavedBeforeTracksStillOpen() throws {
        let json = """
        {"recordingID":"\(UUID().uuidString)","speakers":[{"id":"\(UUID().uuidString)","name":"Ana"}],
         "segments":[{"id":"\(UUID().uuidString)","startTime":0,"endTime":1,"text":"Hola","words":[]}],
         "metadata":{"engine":"WhisperKit","engineVersion":"1.1.0","modelID":"m","createdAt":0}}
        """
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))

        XCTAssertNil(transcript.speakers[0].role)
        XCTAssertNil(transcript.segments[0].source)
        XCTAssertNil(transcript.metadata.trackMode)
        XCTAssertFalse(transcript.isPerTrack)
    }

    func testTrackDetailsSurviveSaving() throws {
        let merged = TrackTranscriptMerger.merge(
            system: [segment("Hola", at: 0, source: .system)],
            microphone: [segment("Chao", at: 5, source: .microphone)]
        )
        let transcript = Transcript(
            recordingID: UUID(),
            speakers: merged.speakers,
            segments: merged.segments,
            metadata: TranscriptMetadata(engine: "test", engineVersion: "1", modelID: "m", trackMode: .perTrack)
        )

        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))

        XCTAssertEqual(decoded, transcript)
        XCTAssertTrue(decoded.isPerTrack)
    }

    // MARK: Helpers

    private func segment(_ text: String, at start: TimeInterval, source: TranscriptSource) -> TranscriptSegment {
        let tokens = text.split(separator: " ").map(String.init)
        let words = tokens.enumerated().map { index, token in
            TranscriptWord(
                startTime: start + Double(index) * 0.3,
                endTime: start + Double(index) * 0.3 + 0.25,
                text: " " + token
            )
        }
        return TranscriptSegment(
            startTime: start,
            endTime: start + Double(tokens.count) * 0.3,
            text: text,
            words: words,
            source: source
        )
    }

    private func dualRecording() -> (Recording, system: AudioAsset, microphone: AudioAsset) {
        let system = AudioAsset(
            originalFileName: "System Audio.m4a",
            fileExtension: "m4a",
            metadata: AudioMetadata(duration: 30, codec: "AAC", sampleRate: 48_000, channelCount: 2),
            role: .systemOriginal
        )
        let microphone = AudioAsset(
            originalFileName: "Microphone.m4a",
            fileExtension: "m4a",
            metadata: AudioMetadata(duration: 30, codec: "AAC", sampleRate: 48_000, channelCount: 1),
            role: .microphoneOriginal,
            timelineOffset: 0.2
        )
        let mix = AudioAsset(
            originalFileName: "Conversation Mix.m4a",
            fileExtension: "m4a",
            metadata: AudioMetadata(duration: 30.2, codec: "AAC", sampleRate: 48_000, channelCount: 2),
            role: .conversationMix,
            derivedFromAssetIDs: [system.id, microphone.id]
        )
        let recording = Recording(
            title: "Reunión",
            duration: 30.2,
            sources: [.systemAudio, .microphone],
            audioAssets: [system, microphone, mix]
        )
        return (recording, system, microphone)
    }
}

/// Remembers the track mode each transcription was asked for.
private actor TrackModeLog {
    private(set) var modes: [TranscriptionTrackMode] = []
    func record(_ mode: TranscriptionTrackMode) { modes.append(mode) }
}

private struct TrackModeTranscriber: RecordingTranscribing {
    let log: TrackModeLog

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        XCTFail("The view model must ask with a track mode")
        throw CancellationError()
    }

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        trackMode: TranscriptionTrackMode,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void,
        liveUpdate: @escaping @Sendable (TranscriptionLiveSnapshot) -> Void
    ) async throws -> Transcript {
        await log.record(trackMode)
        return Transcript(
            recordingID: recording.id,
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Hola")],
            metadata: TranscriptMetadata(engine: "Test", engineVersion: "1", modelID: "fixture", trackMode: trackMode)
        )
    }
}

final class TrackModeSelectionTests: XCTestCase {
    @MainActor
    func testTheChosenTrackModeReachesTheTranscriber() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoTrackMode-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try AudioTestFixture.makeWAV(at: source, sampleRate: 16_000, duration: 1)

        let store = RecordingStore(rootURL: root.appendingPathComponent("Library", isDirectory: true))
        _ = try await AudioImportService(store: store).importFile(at: source)
        let log = TrackModeLog()
        let model = LibraryViewModel(
            store: store,
            transcriptStore: TranscriptStore(rootURL: root.appendingPathComponent("Library", isDirectory: true)),
            transcriber: TrackModeTranscriber(log: log)
        )
        await model.reload()

        await model.performSelectedTranscription(trackMode: .mix)
        await model.performSelectedTranscription(trackMode: .perTrack)

        let modes = await log.modes
        XCTAssertEqual(modes, [.mix, .perTrack])
        XCTAssertEqual(model.transcript?.metadata.trackMode, .perTrack)
    }
}

final class TrackEchoDetectorTests: XCTestCase {
    /// Speech-like loudness: syllables rising and falling irregularly.
    private let call: [Float] = (0..<400).map { index in
        let syllable = sin(Double(index) * 0.45) + 0.6 * sin(Double(index) * 0.13)
        return Float(-3 + syllable)
    }

    func testTheCallHeardAgainAMomentLaterIsAnEcho() {
        let delayFrames = 3 // 60 ms, as measured through this Mac's speakers
        let echo = Array(repeating: Float(-5), count: delayFrames) + call.dropLast(delayFrames).map { $0 * 0.6 - 2 }
        let segment = TranscriptSegment(startTime: 1, endTime: 5, text: "eco", source: .microphone)

        XCTAssertTrue(TrackEchoDetector.isEcho(
            segment,
            microphone: TrackLoudness(offset: 0, levels: echo),
            system: TrackLoudness(offset: 0, levels: call)
        ))
    }

    func testADifferentVoiceIsNotAnEcho() {
        let ownVoice: [Float] = (0..<400).map { Float(-3 + cos(Double($0) * 0.31) + 0.5 * sin(Double($0) * 0.07)) }
        let segment = TranscriptSegment(startTime: 1, endTime: 5, text: "mi voz", source: .microphone)

        XCTAssertFalse(TrackEchoDetector.isEcho(
            segment,
            microphone: TrackLoudness(offset: 0, levels: ownVoice),
            system: TrackLoudness(offset: 0, levels: call)
        ))
    }

    func testNothingEchoesASilentCall() {
        let silence = Array(repeating: Float(-6), count: 400)
        let segment = TranscriptSegment(startTime: 1, endTime: 5, text: "hola", source: .microphone)

        XCTAssertFalse(TrackEchoDetector.isEcho(
            segment,
            microphone: TrackLoudness(offset: 0, levels: call),
            system: TrackLoudness(offset: 0, levels: silence)
        ))
    }
}
