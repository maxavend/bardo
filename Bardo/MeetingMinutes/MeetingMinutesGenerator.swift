import Foundation

struct MeetingMinutesGenerator: MeetingMinutesGenerating {
    static let defaultModelID = MeetingMinutesModel.modelID

    private static let sharedGeneratorResult: Result<MeetingMinutesGenerator, Error> = Result {
        let modelRootURL = try MeetingMinutesModelResourceResolver.managedRoot()
        return MeetingMinutesGenerator(
            textGenerator: MLXTextGenerator(modelRootURL: modelRootURL),
            modelID: MeetingMinutesModel.modelID
        )
    }

    private let textGenerator: any MeetingMinutesTextGenerating
    private let modelID: String
    private let chunkingConfiguration: MeetingMinutesChunkingConfiguration
    private let dateProvider: @Sendable () -> Date

    init(
        textGenerator: any MeetingMinutesTextGenerating,
        modelID: String = MeetingMinutesModel.modelID,
        chunkingConfiguration: MeetingMinutesChunkingConfiguration = .init(),
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.textGenerator = textGenerator
        self.modelID = modelID
        self.chunkingConfiguration = chunkingConfiguration
        self.dateProvider = dateProvider
    }

    static func live() throws -> MeetingMinutesGenerator {
        try sharedGeneratorResult.get()
    }

    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await prepareForSetup { snapshot in
            let fraction: Double
            switch snapshot.stage {
            case .downloading:
                fraction = 0.70 * snapshot.fractionCompleted
            case .loading:
                fraction = 0.70 + (0.20 * snapshot.fractionCompleted)
            case .checkingRuntime:
                fraction = 0.90 + (0.10 * snapshot.fractionCompleted)
            }
            progress(min(1, max(0, fraction)))
        }
    }

    func prepareForSetup(
        progress: @escaping @Sendable (MeetingMinutesSetupProgressSnapshot) -> Void
    ) async throws {
        try await textGenerator.prepareForUse(setupProgress: progress)
    }

    func reset() async {
        await textGenerator.reset()
    }

    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (MeetingMinutesProgressSnapshot) -> Void,
        onStreamChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> MeetingMinutes {
        try Task.checkCancellation()
        let generationStart = ProcessInfo.processInfo.systemUptime
        let chunks = MeetingMinutesPromptBuilder.chunks(
            for: input.transcript,
            configuration: chunkingConfiguration
        )
        guard !chunks.isEmpty else { throw MeetingMinutesError.emptyTranscript }

        let mapOptions = MeetingMinutesGenerationOptions(maxTokens: 1_400, temperature: 0, topP: 0.9)
        let reduceOptions = MeetingMinutesGenerationOptions(maxTokens: 2_048, temperature: 0, topP: 0.9)
        let renderOptions = MeetingMinutesGenerationOptions(maxTokens: 3_072, temperature: 0, topP: 0.9)
        var evidence = [MeetingEvidence]()

        progress(.init(
            stage: .preparingModel,
            fractionCompleted: 0,
            message: String(localized: "Preparing the conversation…")
        ))
        try await textGenerator.prepareForUse { (setupSnapshot: MeetingMinutesSetupProgressSnapshot) in
            let message: String
            switch setupSnapshot.stage {
            case .downloading:
                message = String(localized: "Preparing the conversation…")
            case .loading:
                message = String(localized: "Getting everything ready…")
            case .checkingRuntime:
                message = String(localized: "Getting everything ready…")
            }
            progress(.init(
                stage: .preparingModel,
                fractionCompleted: 0,
                message: message
            ))
        }

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let start = Double(index) / Double(chunks.count + 2)
            progress(.init(
                stage: .extracting(current: index + 1, total: chunks.count),
                fractionCompleted: start,
                message: String.localizedStringWithFormat(
                    String(localized: "Reviewing the conversation · part %lld of %lld…"),
                    index + 1,
                    chunks.count
                )
            ))

            let raw = try await textGenerator.generate(
                prompt: MeetingMinutesPromptBuilder.extractionPrompt(
                    chunk: chunk,
                    transcript: input.transcript,
                    title: input.title,
                    context: input.context,
                    languageCode: input.transcript.languageCode
                ),
                options: mapOptions,
                progress: { value in
                    let fraction = (Double(index) + value) / Double(chunks.count + 2)
                    progress(.init(
                        stage: .extracting(current: index + 1, total: chunks.count),
                        fractionCompleted: fraction,
                        message: String.localizedStringWithFormat(
                            String(localized: "Reviewing the conversation · part %lld of %lld…"),
                            index + 1,
                            chunks.count
                        )
                    ))
                },
                onStreamChunk: nil
            )
            let parsed = Self.decodeEvidence(raw) ?? Self.fallbackEvidence(
                for: chunk,
                topic: input.title
            )
            evidence.append(contentsOf: parsed.map { Self.restrictToChunk($0, chunk: chunk) })
        }

        try Task.checkCancellation()
        let reducedEvidence = MeetingMinutesEvidenceReducer.reduce(evidence)
        let encodedEvidence = try Self.encode(reducedEvidence)
        let reduceStart = Double(chunks.count) / Double(chunks.count + 2)
        progress(.init(
            stage: .synthesizing,
            fractionCompleted: reduceStart,
            message: String(localized: "Organizing decisions and pending items…")
        ))

        let rawAnalysis = try await textGenerator.generate(
            prompt: MeetingMinutesPromptBuilder.consolidationPrompt(
                evidenceJSON: encodedEvidence,
                title: input.title,
                context: input.context,
                languageCode: input.transcript.languageCode
            ),
            options: reduceOptions,
            progress: { value in
                progress(.init(
                    stage: .synthesizing,
                    fractionCompleted: reduceStart + (value / Double(chunks.count + 2)),
                    message: String(localized: "Organizing decisions and pending items…")
                ))
            },
            onStreamChunk: nil
        )
        let analysis = Self.decodeAnalysis(rawAnalysis)
            ?? MeetingMinutesEvidenceReducer.fallbackAnalysis(from: reducedEvidence)
        let analysisJSON = try Self.encode(analysis)

        progress(.init(
            stage: .synthesizing,
            fractionCompleted: (Double(chunks.count) + 1) / Double(chunks.count + 2),
            message: String(localized: "Writing the meeting minutes…")
        ))
        let rendered = try await textGenerator.generate(
            prompt: MeetingMinutesPromptBuilder.renderPrompt(
                analysisJSON: analysisJSON,
                title: input.title,
                context: input.context,
                languageCode: input.transcript.languageCode
            ),
            options: renderOptions,
            progress: { value in
                progress(.init(
                    stage: .synthesizing,
                    fractionCompleted: min(1, max(0, (Double(chunks.count) + 1 + value) / Double(chunks.count + 2))),
                    message: String(localized: "Writing the meeting minutes…")
                ))
            },
            onStreamChunk: onStreamChunk
        )
        let renderedText = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !renderedText.isEmpty else { throw MeetingMinutesError.emptyGeneratedText }

        progress(.init(
            stage: .synthesizing,
            fractionCompleted: 1,
            message: String(localized: "Meeting minutes ready.")
        ))
        let processingDuration = max(0, ProcessInfo.processInfo.systemUptime - generationStart)
        return MeetingMinutes(
            recordingID: input.transcript.recordingID,
            sourceTranscriptMetadata: input.transcript.metadata,
            modelID: modelID,
            text: renderedText,
            createdAt: dateProvider(),
            analysis: analysis,
            sourceTranscriptHash: TranscriptFingerprint.hash(input.transcript),
            modelRevision: MeetingMinutesModel.modelRevision,
            promptVersion: MeetingMinutesPromptBuilder.promptVersion,
            pipelineVersion: MeetingMinutesPromptBuilder.pipelineVersion,
            processingDuration: processingDuration
        )
    }

    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> MeetingMinutes {
        try await generate(
            from: input,
            progress: { snapshot in progress(snapshot.fractionCompleted) },
            onStreamChunk: nil
        )
    }

    private static func restrictToChunk(_ evidence: MeetingEvidence, chunk: MeetingMinutesChunk) -> MeetingEvidence {
        let allowed = Set(chunk.sourceSegmentIDs)
        let sourceIDs = evidence.sourceSegmentIDs.filter { allowed.contains($0) }
        return MeetingEvidence(
            type: evidence.type,
            topic: evidence.topic,
            statement: evidence.statement,
            rationale: evidence.rationale,
            responsible: evidence.responsible,
            validator: evidence.validator,
            certainty: evidence.certainty,
            sourceSegmentIDs: sourceIDs.isEmpty ? chunk.sourceSegmentIDs : sourceIDs,
            startTime: evidence.startTime ?? chunk.segments.first?.startTime,
            endTime: evidence.endTime ?? chunk.segments.last?.endTime
        )
    }

    private static func decodeEvidence(_ text: String) -> [MeetingEvidence]? {
        guard let data = jsonData(in: text) else { return nil }
        if let values = try? JSONDecoder().decode([MeetingEvidence].self, from: data) {
            return values
        }
        struct Envelope: Decodable { let evidence: [MeetingEvidence] }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.evidence
    }

    private static func decodeAnalysis(_ text: String) -> MeetingAnalysis? {
        guard let data = jsonData(in: text) else { return nil }
        return try? JSONDecoder().decode(MeetingAnalysis.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func jsonData(in text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = unwrapped.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = unwrapped.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let end = unwrapped.lastIndex(where: { $0 == "]" || $0 == "}" }),
              start <= end else { return nil }
        return String(unwrapped[start...end]).data(using: .utf8)
    }

    private static func fallbackEvidence(
        for chunk: MeetingMinutesChunk,
        topic: String
    ) -> [MeetingEvidence] {
        chunk.segments.compactMap { segment in
            let statement = segment.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else { return nil }
            return MeetingEvidence(
                type: .context,
                topic: topic,
                statement: statement,
                certainty: .qualified,
                sourceSegmentIDs: [segment.id],
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }
    }
}

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// The only model/runtime-specific implementation used by the minutes pipeline.
actor MLXTextGenerator: MeetingMinutesTextGenerating {
    static let defaultIdleUnloadNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    private let modelRootURL: URL
    private let idleUnloadNanoseconds: UInt64
    private var container: ModelContainer?
    private var idleUnloadTask: Task<Void, Never>?

    init(
        modelRootURL: URL,
        idleUnloadNanoseconds: UInt64 = MLXTextGenerator.defaultIdleUnloadNanoseconds
    ) {
        self.modelRootURL = modelRootURL.standardizedFileURL
        self.idleUnloadNanoseconds = idleUnloadNanoseconds
    }

    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await prepareForUse { (snapshot: MeetingMinutesSetupProgressSnapshot) in
            let fraction: Double
            switch snapshot.stage {
            case .downloading:
                fraction = 0.70 * snapshot.fractionCompleted
            case .loading:
                fraction = 0.70 + (0.20 * snapshot.fractionCompleted)
            case .checkingRuntime:
                fraction = 0.90 + (0.10 * snapshot.fractionCompleted)
            }
            progress(min(1, max(0, fraction)))
        }
    }

    func prepareForUse(
        setupProgress: @escaping @Sendable (MeetingMinutesSetupProgressSnapshot) -> Void
    ) async throws {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        do {
            if MeetingMinutesRuntimeReadiness.isReady(), container != nil {
                setupProgress(.init(stage: .loading, fractionCompleted: 1))
                setupProgress(.init(stage: .checkingRuntime, fractionCompleted: 1))
                scheduleIdleUnload()
                return
            }

            if !MeetingMinutesRuntimeReadiness.isReady() {
                setupProgress(.init(stage: .downloading, fractionCompleted: 0))
                _ = try await MeetingMinutesModelDownloader.ensureAvailable(
                    managedRoot: modelRootURL,
                    progress: { fraction in
                        setupProgress(.init(
                            stage: .downloading,
                            fractionCompleted: min(1, max(0, fraction))
                        ))
                    }
                )
            }

            try Task.checkCancellation()
            setupProgress(.init(stage: .loading, fractionCompleted: 0))
            let loaded = try await loadContainer { fraction in
                setupProgress(.init(
                    stage: .loading,
                    fractionCompleted: min(1, max(0, fraction))
                ))
            }
            setupProgress(.init(stage: .loading, fractionCompleted: 1))

            if !MeetingMinutesRuntimeReadiness.isReady() {
                try Task.checkCancellation()
                setupProgress(.init(stage: .checkingRuntime, fractionCompleted: 0))
                try await runHealthCheck(using: loaded)
                MeetingMinutesRuntimeReadiness.markReady()
            }
            setupProgress(.init(stage: .checkingRuntime, fractionCompleted: 1))
            scheduleIdleUnload()
        } catch {
            MeetingMinutesRuntimeReadiness.invalidate()
            container = nil
            throw error
        }
    }

    func reset() async {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        container = nil
    }

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void,
        onStreamChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        defer { scheduleIdleUnload() }
        let container = try await loadContainer(progress: progress)
        let input = try await container.prepare(input: UserInput(chat: [
            .system("You are Bardo's conservative meeting-minutes writer. Use only the user's transcript evidence."),
            .user(prompt)
        ]))
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(
                maxTokens: options.maxTokens,
                temperature: options.temperature,
                topP: options.topP,
                topK: 40,
                repetitionPenalty: options.repetitionPenalty ?? 1.1,
                repetitionContextSize: options.repetitionContextSize
            )
        )

        var output = ""
        let stopTokens = ["<|im_end|>", "<|endoftext|>", "<|end_of_text|>", "<|assistant|>"]
        for await generation in stream {
            try Task.checkCancellation()
            guard case .chunk(let chunk) = generation else { continue }
            var cleanChunk = chunk
            var shouldStop = false
            for stop in stopTokens {
                if let range = cleanChunk.range(of: stop) {
                    cleanChunk = String(cleanChunk[..<range.lowerBound])
                    shouldStop = true
                    break
                }
            }
            if !cleanChunk.isEmpty {
                output.append(cleanChunk)
                onStreamChunk?(cleanChunk)
            }
            if shouldStop || RepetitionDetector.detectRepetition(in: output) != nil { break }
        }
        progress(1)
        let cleaned = RepetitionDetector.cleanRepetition(from: output)
        return cleaned.isEmpty ? output : cleaned
    }

    private func runHealthCheck(using container: ModelContainer) async throws {
        let input = try await container.prepare(input: UserInput(chat: [
            .system("You are performing a local runtime health check."),
            .user("Reply with READY.")
        ]))
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(
                maxTokens: 8,
                temperature: 0,
                topP: 1,
                topK: 20,
                repetitionPenalty: 1,
                repetitionContextSize: 16
            )
        )

        var output = ""
        let stopTokens = ["<|im_end|>", "<|endoftext|>", "<|end_of_text|>", "<|assistant|>"]
        for await generation in stream {
            try Task.checkCancellation()
            guard case .chunk(let chunk) = generation else { continue }
            var cleanChunk = chunk
            for stop in stopTokens {
                cleanChunk = cleanChunk.replacingOccurrences(of: stop, with: "")
            }
            output.append(cleanChunk)
            if output.lowercased().contains("ready") { break }
        }

        guard output.lowercased().contains("ready") else {
            throw MeetingMinutesError.modelNotAvailable(
                "LFM2.5 loaded, but Bardo could not complete its local generation check."
            )
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadNanoseconds
        idleUnloadTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.unloadAfterIdleTimeout()
        }
    }

    private func unloadAfterIdleTimeout() {
        container = nil
        idleUnloadTask = nil
    }

    private func loadContainer(progress: @escaping @Sendable (Double) -> Void) async throws -> ModelContainer {
        if let container { return container }
        let modelDirectory = try MeetingMinutesModelResourceResolver.resolve(
            applicationSupportRoot: modelRootURL
        )
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        progress(1)
        container = loaded
        return loaded
    }
}
#else
struct MLXTextGenerator: MeetingMinutesTextGenerating {
    init(modelRootURL: URL) { _ = modelRootURL }

    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0)
        throw MeetingMinutesError.modelNotAvailable(
            "MLXSwiftLM, Hugging Face, and Tokenizers are not linked in this build."
        )
    }

    func reset() async {}

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void,
        onStreamChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        _ = prompt
        _ = options
        _ = progress
        _ = onStreamChunk
        throw MeetingMinutesError.modelNotAvailable(
            "MLXSwiftLM, Hugging Face, and Tokenizers are not linked in this build."
        )
    }
}
#endif
