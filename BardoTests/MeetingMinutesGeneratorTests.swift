import Foundation
import XCTest
@testable import Bardo

final class MeetingMinutesGeneratorTests: XCTestCase {

    func testProductionMinutesModelUsesImmutablePinnedRevision() {
        XCTAssertEqual(
            MeetingMinutesModel.modelRevision,
            "125e006d991147f3b432249d1bdf0821987f12b0"
        )
        XCTAssertNotEqual(MeetingMinutesModel.modelRevision, "main")
    }

    func testRuntimeReadyRequiresBothSuccessfulMarkerAndCompleteSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoMinutesReady-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "BardoMinutesReadyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        try Data(MeetingMinutesModel.modelRevision.utf8).write(
            to: root.appendingPathComponent(MeetingMinutesModel.revisionMarkerFileName)
        )
        let weights = root.appendingPathComponent("model.safetensors")
        try Data("weights".utf8).write(to: weights)

        XCTAssertFalse(
            MeetingMinutesRuntimeReadiness.isReady(
                applicationSupportRoot: root,
                defaults: defaults
            )
        )

        MeetingMinutesRuntimeReadiness.markReady(defaults: defaults)
        XCTAssertTrue(
            MeetingMinutesRuntimeReadiness.isReady(
                applicationSupportRoot: root,
                defaults: defaults
            )
        )

        try FileManager.default.removeItem(at: weights)
        XCTAssertFalse(
            MeetingMinutesRuntimeReadiness.isReady(
                applicationSupportRoot: root,
                defaults: defaults
            )
        )
    }

    func testInputContainsOnlyTranscriptTitleAndContextEvenWhenRecordingHasAudioAssets() throws {
        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
        let recording = Recording(
            id: recordingID,
            title: "Audio source that must never reach the minutes model",
            sources: [.importedFile],
            audioAssets: [
                AudioAsset(
                    originalFileName: "private-audio.wav",
                    fileExtension: "wav",
                    metadata: AudioMetadata(
                        duration: 12,
                        codec: "pcm",
                        sampleRate: 16_000,
                        channelCount: 1
                    )
                )
            ]
        )
        let input = MeetingMinutesInput(
            transcript: makeTranscript(recordingID: recording.id, text: "Discuss launch."),
            title: recording.title,
            context: "Planning"
        )

        let labels = Mirror(reflecting: input).children.compactMap(\.label)
        XCTAssertEqual(labels, ["transcript", "title", "context"])
        XCTAssertFalse(String(describing: input).contains("private-audio.wav"))
        XCTAssertFalse(String(describing: input).contains("URL"))
        XCTAssertFalse(String(describing: input).contains("[Float]"))
    }

    func testGeneratorUsesDeterministicConservativeTextOnlyPrompt() async throws {
        let spy = TextGeneratorSpy(responses: ["## Summary\n- Launch was discussed."])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_602)
        let generator = MeetingMinutesGenerator(
            textGenerator: spy,
            dateProvider: { createdAt }
        )
        let input = MeetingMinutesInput(
            transcript: makeTranscript(recordingID: UUID(), text: "Maxi asked whether we should launch."),
            title: "Product planning",
            context: "Weekly meeting"
        )

        let result = try await generator.generate(from: input, progress: { _ in })
        let prompts = await spy.prompts

        XCTAssertEqual(result.modelID, MeetingMinutesModel.modelID)
        XCTAssertEqual(result.text, "## Summary\n- Launch was discussed.")
        XCTAssertEqual(result.createdAt, createdAt)
        XCTAssertEqual(prompts.count, 3)
        XCTAssertTrue(prompts[0].contains("Product planning"))
        XCTAssertTrue(prompts[0].contains("Weekly meeting"))
        XCTAssertTrue(prompts[0].contains("Maxi asked whether we should launch."))
        XCTAssertTrue(prompts[0].contains("Do not infer external knowledge, advice, deadlines, names, or decisions."))
        XCTAssertTrue(prompts[0].contains("A question is not an agreement."))
        XCTAssertFalse(prompts[0].contains("private-audio.wav"))
        XCTAssertFalse(prompts[0].contains("samples"))
        let options = await spy.options
        XCTAssertEqual(options.first?.temperature, 0)
    }

    func testLongTranscriptUsesSegmentBoundedExtractionThenFinalSynthesis() async throws {
        let spy = TextGeneratorSpy(responses: [
            #"[{"type":"context","topic":"First","statement":"Extract one","certainty":"qualified","sourceSegmentIDs":[]}]"#,
            #"[{"type":"context","topic":"Second","statement":"Extract two","certainty":"qualified","sourceSegmentIDs":[]}]"#,
            "Final minutes"
        ])
        let generator = MeetingMinutesGenerator(
            textGenerator: spy,
            chunkingConfiguration: .init(targetTokens: 20, overlapSegmentCount: 0),
            dateProvider: { Date(timeIntervalSince1970: 1_700_000_603) }
        )
        let transcript = Transcript(
            recordingID: UUID(),
            speakers: [Speaker(name: "Maxi")],
            segments: [
                TranscriptSegment(startTime: 0, endTime: 1, speakerID: nil, text: String(repeating: "first ", count: 20)),
                TranscriptSegment(startTime: 2, endTime: 3, speakerID: nil, text: String(repeating: "second ", count: 20))
            ],
            metadata: TranscriptMetadata(engine: "WhisperKit", engineVersion: "test", modelID: "test")
        )

        let result = try await generator.generate(
            from: MeetingMinutesInput(transcript: transcript, title: "Long meeting", context: nil),
            progress: { _ in }
        )
        let prompts = await spy.prompts

        XCTAssertEqual(result.text, "Final minutes")
        XCTAssertEqual(prompts.count, 4)
        XCTAssertTrue(prompts[0].contains("MAP: extract conservative"))
        XCTAssertTrue(prompts[1].contains("MAP: extract conservative"))
        XCTAssertTrue(prompts[2].contains("REDUCE: reconstruct"))
        XCTAssertTrue(prompts[2].contains("Extract one"))
        XCTAssertTrue(prompts[2].contains("Extract two"))
        XCTAssertTrue(prompts[3].contains("RENDER: write"))
    }

    func testGeneratorIncludesLanguageInstructionInPrompt() async throws {
        let spy = TextGeneratorSpy(responses: ["## Resumen\n- Acuerdo alcanzado."])
        let generator = MeetingMinutesGenerator(textGenerator: spy)
        var transcript = makeTranscript(recordingID: UUID(), text: "Discutimos el lanzamiento del producto.")
        transcript.languageCode = "es"

        let input = MeetingMinutesInput(
            transcript: transcript,
            title: "Reunión de Producto",
            context: "Planificación semanal"
        )

        _ = try await generator.generate(from: input, progress: { (_: MeetingMinutesProgressSnapshot) in }, onStreamChunk: nil)
        let prompts = await spy.prompts

        XCTAssertEqual(prompts.count, 3)
        XCTAssertTrue(prompts[0].contains("Spanish"))
        XCTAssertTrue(prompts[0].contains("es"))
        XCTAssertTrue(prompts[0].contains("LANGUAGE REQUIREMENT"))
        XCTAssertTrue(prompts[0].contains("Return JSON only"))
        XCTAssertTrue(prompts[1].contains("REDUCE: reconstruct"))
        XCTAssertTrue(prompts[2].contains("RENDER: write"))
    }

    func testGeneratorStreamsTokensDuringSynthesis() async throws {
        let spy = TextGeneratorSpy(responses: ["Streaming chunk"])
        let generator = MeetingMinutesGenerator(textGenerator: spy)
        let input = MeetingMinutesInput(
            transcript: makeTranscript(recordingID: UUID(), text: "Test conversation."),
            title: "Testing Stream",
            context: nil
        )

        let receivedChunks = LockedBox<[String]>([])
        _ = try await generator.generate(
            from: input,
            progress: { (_: MeetingMinutesProgressSnapshot) in },
            onStreamChunk: { chunk in
                receivedChunks.append(chunk)
            }
        )

        let chunks = receivedChunks.value
        XCTAssertEqual(chunks, ["Streaming chunk"])
    }

    func testGeneratorReportsProgressSnapshotsWithStages() async throws {
        let spy = TextGeneratorSpy(responses: ["Completed minutes"])
        let generator = MeetingMinutesGenerator(textGenerator: spy)
        let input = MeetingMinutesInput(
            transcript: makeTranscript(recordingID: UUID(), text: "Quick check."),
            title: "Progress Check",
            context: nil
        )

        let snapshots = LockedBox<[MeetingMinutesProgressSnapshot]>([])
        _ = try await generator.generate(
            from: input,
            progress: { snapshot in
                snapshots.append(snapshot)
            },
            onStreamChunk: nil
        )

        let values = snapshots.value
        let stages = values.map(\.stage)
        XCTAssertTrue(stages.contains(.preparingModel))
        XCTAssertTrue(stages.contains(.synthesizing))
        XCTAssertEqual(values.last?.fractionCompleted, 1)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { pair in
            pair.0.fractionCompleted <= pair.1.fractionCompleted
        })
    }

    func testInvalidExtractionFallsBackToTranscriptSegmentsInsteadOfModelProse() async throws {
        let spy = TextGeneratorSpy(responses: ["not valid json", "not valid analysis", "Final minutes"])
        let generator = MeetingMinutesGenerator(textGenerator: spy)
        let transcript = makeTranscript(recordingID: UUID(), text: "Figma needs an empty state before handoff.")

        _ = try await generator.generate(
            from: MeetingMinutesInput(transcript: transcript, title: "Design review", context: nil),
            progress: { (_: MeetingMinutesProgressSnapshot) in },
            onStreamChunk: nil
        )

        let prompts = await spy.prompts
        XCTAssertEqual(prompts.count, 3)
        XCTAssertTrue(prompts[1].contains("Figma needs an empty state before handoff."))
        XCTAssertFalse(prompts[1].contains("not valid json"))
    }

    func testRepetitionDetectorIdentifiesLineLevelLoopsAndCleans() {
        let loopedText = """
        # Minuta de Reunión
        ## Acuerdos y Decisiones
        - Se acordó posponer la fecha de entrega al 15 de noviembre.
        - Se acordó posponer la fecha de entrega al 15 de noviembre.
        - Se acordó posponer la fecha de entrega al 15 de noviembre.
        """

        let cut = RepetitionDetector.detectRepetition(in: loopedText)
        XCTAssertNotNil(cut)

        let cleaned = RepetitionDetector.cleanRepetition(from: loopedText)
        XCTAssertTrue(cleaned.contains("- Se acordó posponer la fecha de entrega al 15 de noviembre."))
        // Must contain it only once, not 3 times
        let occurrences = cleaned.components(separatedBy: "- Se acordó posponer la fecha de entrega al 15 de noviembre.").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testRepetitionDetectorIdentifiesSubstringCyclesAndCleans() {
        let loopedText = "El equipo discutió los objetivos del trimestre. y luego revisamos los puntos pendientes y luego revisamos los puntos pendientes y luego revisamos los puntos pendientes"
        let cut = RepetitionDetector.detectRepetition(in: loopedText)
        XCTAssertNotNil(cut)

        let cleaned = RepetitionDetector.cleanRepetition(from: loopedText)
        let occurrences = cleaned.components(separatedBy: "y luego revisamos los puntos pendientes").count - 1
        XCTAssertEqual(occurrences, 1)
        XCTAssertTrue(cleaned.hasPrefix("El equipo discutió los objetivos del trimestre."))
    }

    func testRepetitionDetectorLeavesNormalTextIntact() {
        let normalText = """
        # Minuta de Reunión
        ## Resumen Ejecutivo
        Se discutió la arquitectura del proyecto y las dependencias de red.
        ## Acuerdos y Decisiones
        - Maxi coordinará la migración.
        - Sofía revisará las pruebas de integración.
        ## Tareas
        - Documentar los cambios antes del viernes.
        """
        let cut = RepetitionDetector.detectRepetition(in: normalText)
        XCTAssertNil(cut)
        XCTAssertEqual(RepetitionDetector.cleanRepetition(from: normalText), normalText)
    }

    private func makeTranscript(recordingID: Recording.ID, text: String) -> Transcript {
        Transcript(
            recordingID: recordingID,
            languageCode: "en",
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: text)],
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: "test",
                modelID: "large-v3-v20240930_turbo_632MB"
            )
        )
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func append<Element>(_ element: Element) where T == [Element] {
        lock.lock()
        defer { lock.unlock() }
        _value.append(element)
    }
}

private actor TextGeneratorSpy: MeetingMinutesTextGenerating {
    struct Call: Sendable {
        let prompt: String
        let options: MeetingMinutesGenerationOptions
    }

    private let responses: [String]
    private var index = 0
    private(set) var calls: [Call] = []

    init(responses: [String]) {
        self.responses = responses
    }

    var prompts: [String] {
        calls.map(\.prompt)
    }

    var options: [MeetingMinutesGenerationOptions] {
        calls.map(\.options)
    }

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void,
        onStreamChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        calls.append(Call(prompt: prompt, options: options))
        progress(1)
        defer { index += 1 }
        let resp = responses[min(index, responses.count - 1)]
        onStreamChunk?(resp)
        return resp
    }

    func reset() async {}
}
