import Foundation

struct QwenMeetingMinutesGenerator: MeetingMinutesGenerating {
    static let defaultModelID = QwenMeetingMinutesModel.modelID
    private static let sharedGeneratorResult: Result<QwenMeetingMinutesGenerator, Error> = Result {
        let store = try BardoModelStore.live()
        return QwenMeetingMinutesGenerator(
            textGenerator: QwenMLXTextGenerator(modelRootURL: QwenMeetingMinutesModel.root(using: store))
        )
    }

    private let textGenerator: any MeetingMinutesTextGenerating
    private let modelID: String
    private let chunkCharacterLimit: Int
    private let dateProvider: @Sendable () -> Date

    init(
        textGenerator: any MeetingMinutesTextGenerating,
        modelID: String = QwenMeetingMinutesModel.modelID,
        chunkCharacterLimit: Int = MeetingMinutesPromptBuilder.defaultChunkCharacterLimit,
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.textGenerator = textGenerator
        self.modelID = modelID
        self.chunkCharacterLimit = max(1, chunkCharacterLimit)
        self.dateProvider = dateProvider
    }

    static func live() throws -> QwenMeetingMinutesGenerator {
        try sharedGeneratorResult.get()
    }

    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await textGenerator.prepareForUse(progress: progress)
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
        let chunks = MeetingMinutesPromptBuilder.chunks(
            for: input.transcript,
            characterLimit: chunkCharacterLimit
        )
        guard !chunks.isEmpty else { throw MeetingMinutesError.emptyTranscript }

        progress(MeetingMinutesProgressSnapshot(
            stage: .preparingModel,
            fractionCompleted: 0,
            message: String(localized: "Preparing Qwen model in local memory…")
        ))

        let options = MeetingMinutesGenerationOptions()
        var evidence = [String]()
        let isSingle = chunks.count == 1
        if isSingle {
            evidence = [chunks[0].joined(separator: "\n")]
        } else {
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let currentFraction = Double(index) / Double(chunks.count + 1)
                progress(MeetingMinutesProgressSnapshot(
                    stage: .extracting(current: index + 1, total: chunks.count),
                    fractionCompleted: currentFraction,
                    message: String.localizedStringWithFormat(
                        String(localized: "Analyzing section %lld of %lld…"),
                        index + 1,
                        chunks.count
                    )
                ))
                let extraction = try await textGenerator.generate(
                    prompt: MeetingMinutesPromptBuilder.extractionPrompt(
                        lines: chunk,
                        title: input.title,
                        context: input.context,
                        languageCode: input.transcript.languageCode
                    ),
                    options: options,
                    progress: { value in
                        let stageFraction = (Double(index) + value) / Double(chunks.count + 1)
                        progress(MeetingMinutesProgressSnapshot(
                            stage: .extracting(current: index + 1, total: chunks.count),
                            fractionCompleted: stageFraction,
                            message: String.localizedStringWithFormat(
                                String(localized: "Analyzing section %lld of %lld…"),
                                index + 1,
                                chunks.count
                            )
                        ))
                    },
                    onStreamChunk: nil
                )
                evidence.append(try Self.nonEmptyText(extraction))
            }
        }

        try Task.checkCancellation()
        let synthStartFraction = isSingle ? 0.05 : Double(chunks.count) / Double(chunks.count + 1)
        progress(MeetingMinutesProgressSnapshot(
            stage: .synthesizing,
            fractionCompleted: synthStartFraction,
            message: String(localized: "Writing meeting minutes in real time…")
        ))

        let finalText = try await textGenerator.generate(
            prompt: MeetingMinutesPromptBuilder.synthesisPrompt(
                extractions: evidence,
                title: input.title,
                context: input.context,
                languageCode: input.transcript.languageCode,
                isSingleTranscript: isSingle
            ),
            options: options,
            progress: { value in
                let overall = isSingle
                    ? 0.05 + (value * 0.95)
                    : (Double(chunks.count) + value) / Double(chunks.count + 1)
                progress(MeetingMinutesProgressSnapshot(
                    stage: .synthesizing,
                    fractionCompleted: min(1, max(0, overall)),
                    message: String(localized: "Writing meeting minutes in real time…")
                ))
            },
            onStreamChunk: onStreamChunk
        )
        progress(MeetingMinutesProgressSnapshot(
            stage: .synthesizing,
            fractionCompleted: 1,
            message: String(localized: "Meeting minutes complete.")
        ))

        return MeetingMinutes(
            recordingID: input.transcript.recordingID,
            sourceTranscriptMetadata: input.transcript.metadata,
            modelID: modelID,
            text: try Self.nonEmptyText(finalText),
            createdAt: dateProvider()
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

    private static func nonEmptyText(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetingMinutesError.emptyGeneratedText }
        return text
    }
}

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// MLX integration is intentionally isolated to this adapter. The private HubCache is
/// passed to HubClient explicitly, so Qwen never falls back to HF's process-global cache.
actor QwenMLXTextGenerator: MeetingMinutesTextGenerating {
    private let modelRootURL: URL
    private let modelID: String
    private var container: ModelContainer?

    init(modelRootURL: URL, modelID: String = QwenMeetingMinutesModel.modelID) {
        self.modelRootURL = modelRootURL.standardizedFileURL
        self.modelID = modelID
    }

    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await loadContainer(progress: progress)
    }

    func reset() async {
        container = nil
    }

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void,
        onStreamChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let container = try await loadContainer(progress: progress)
        let input = try await container.prepare(input: UserInput(prompt: prompt))

        let effectiveTemperature: Float = options.temperature <= 0 ? 0.3 : options.temperature
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(
                maxTokens: options.maxTokens,
                temperature: effectiveTemperature,
                topP: options.topP,
                topK: 40,
                repetitionPenalty: options.repetitionPenalty ?? 1.2,
                repetitionContextSize: options.repetitionContextSize,
                presencePenalty: 0.1,
                frequencyPenalty: 0.1
            )
        )

        var output = ""
        let stopTokens = ["<|im_end|>", "<|endoftext|>", "<|im_start|>", "<|end_of_text|>"]

        for await generation in stream {
            try Task.checkCancellation()
            if case .chunk(let chunk) = generation {
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

                if shouldStop {
                    break
                }

                // Check for repetitive loop in generation
                if RepetitionDetector.detectRepetition(in: output) != nil {
                    break
                }
            }
        }

        let cleaned = RepetitionDetector.cleanRepetition(from: output)
        return cleaned.isEmpty ? output : cleaned
    }

    private func loadContainer(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        if let container { return container }

        let cache = HubCache(location: .fixed(directory: modelRootURL))
        let hub = HubClient(cache: cache)
        let configuration = ModelConfiguration(id: modelID)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hub),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: { progress($0.fractionCompleted) }
        )
        container = loaded
        return loaded
    }
}
#else
/// The project keeps the core and tests buildable when MLX packages are not resolved yet.
/// Production builds with the pinned packages use the adapter above. No global cache
/// environment variable is mutated as a fallback.
struct QwenMLXTextGenerator: MeetingMinutesTextGenerating {
    init(modelRootURL: URL, modelID: String = QwenMeetingMinutesModel.modelID) {
        _ = modelID
        _ = modelRootURL
    }

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
