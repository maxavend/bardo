import Foundation

// Writes a Library with Bardo for macOS's own store, for Bardo for Windows to read.
// Usage: make-fixtures <output directory>
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

let mic = AudioAsset(
    id: id(11), originalFileName: "Micrófono.caf", fileExtension: "M4A",
    metadata: AudioMetadata(duration: 187.25, codec: "aac", sampleRate: 32_000, channelCount: 1),
    role: .microphoneOriginal
)
let system = AudioAsset(
    id: id(12), originalFileName: "Sistema.m4a", fileExtension: "m4a",
    metadata: AudioMetadata(duration: 187.5, codec: "aac", sampleRate: 48_000, channelCount: 2),
    role: .systemOriginal, timelineOffset: 0.125
)
let mix = AudioAsset(
    id: id(13), originalFileName: "Conversación.m4a", fileExtension: "m4a",
    metadata: AudioMetadata(duration: 187.5, codec: "aac", sampleRate: 32_000, channelCount: 2),
    role: .conversationMix, derivedFromAssetIDs: [id(11), id(12)]
)
let notes = RecordingNotes(
    moments: [RecordingMoment(id: id(21), time: 42.5, title: "Decisión", note: "Lanzar el jueves")],
    sections: [RecordingSection(id: id(22), start: 0, title: "Contexto"), RecordingSection(id: id(23), start: 90, title: "Cierre")]
)
let recording = Recording(
    id: id(1), title: "Reunión de diseño",
    createdAt: Date(timeIntervalSince1970: 1_761_650_000.123_456_7),
    duration: 187.5, sources: [.systemAudio, .microphone], processingState: .completed,
    audioAssets: [mic, system, mix], notes: notes, skipsSilences: true
)

let store = RecordingStore(rootURL: output)
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let sources: [AudioAsset.ID: URL] = try [mic, system, mix].reduce(into: [:]) { files, asset in
            let url = output.appendingPathComponent("source-\(asset.id.uuidString)")
            try Data("audio".utf8).write(to: url)
            files[asset.id] = url
        }
        try await store.importRecording(recording, audioFiles: sources, transferringOwnership: true)

        let you = Speaker(id: id(31), name: "Maxi", role: .localUser)
        let others = Speaker(id: id(32), role: .others)
        let numbered = Speaker(id: id(33))
        let transcript = Transcript(
            recordingID: recording.id, languageCode: "es",
            speakers: [you, others, numbered],
            segments: [
                TranscriptSegment(
                    id: id(41), startTime: 0.5, endTime: 3.25, speakerID: you.id, text: "Hola, partamos.",
                    words: [
                        TranscriptWord(id: id(51), startTime: 0.5, endTime: 1.0, text: "Hola,", probability: 0.98),
                        TranscriptWord(id: id(52), startTime: 1.1, endTime: 3.25, text: "partamos.")
                    ],
                    source: .microphone
                ),
                TranscriptSegment(
                    id: id(42), startTime: 4, endTime: 9.75, speakerID: numbered.id, text: "Revisemos el empty state.",
                    editedText: "Revisemos el estado vacío.", source: .system
                ),
                TranscriptSegment(id: id(43), startTime: 10, endTime: 12, text: "Sin hablante.")
            ],
            metadata: TranscriptMetadata(
                engine: "WhisperKit", engineVersion: "1.1.0", modelID: "large-v3",
                selection: TranscriptionSelection(backend: .whisperKit, modelID: "large-v3"),
                createdAt: Date(timeIntervalSince1970: 1_761_650_200.5),
                processingDuration: 18.25, trackMode: .perTrack
            ),
            diarizationMetadata: DiarizationMetadata(
                engine: "SpeakerKit", engineVersion: "1.1.0", modelID: "pyannote",
                createdAt: Date(timeIntervalSince1970: 1_761_650_210), processingDuration: 0.75
            )
        )
        try await TranscriptStore(rootURL: output).save(transcript)

        // Older manifests, as earlier versions of Bardo wrote them.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let v1 = RecordingManifestV1(
            schemaVersion: 1, id: id(2), title: "Primera versión", createdAtEpochSeconds: 1_700_000_000,
            duration: nil, sources: [.microphone], processingState: .pending
        )
        let createdAt: TimeInterval = 1_700_000_100.25
        let v2 = RecordingManifestV2(
            schemaVersion: 2, id: id(3), title: "Segunda versión", createdAtEpochSeconds: createdAt,
            createdAtEpochSecondsBitPattern: createdAt.bitPattern, duration: 12, sources: [.systemAudio],
            processingState: .failed,
            audioAssets: [.init(id: id(14), originalFileName: "audio.m4a", fileExtension: "m4a", duration: 12, codec: "aac", sampleRate: 48_000, channelCount: 2)]
        )
        for (manifest, recordingID) in [(try encoder.encode(v1), id(2)), (try encoder.encode(v2), id(3))] {
            let directory = output.appendingPathComponent(recordingID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try manifest.write(to: directory.appendingPathComponent(RecordingStore.manifestFileName))
        }
        let audio = output.appendingPathComponent(id(3).uuidString).appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: audio.appendingPathComponent("\(id(14).uuidString).m4a"))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()
