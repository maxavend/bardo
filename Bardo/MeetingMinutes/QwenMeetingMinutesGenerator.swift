import Foundation

struct QwenMeetingMinutesGenerator: MeetingMinutesGenerating {
    static let defaultModelID = QwenMeetingMinutesModel.modelID

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
        let store = try BardoModelStore.live()
        return QwenMeetingMinutesGenerator(
            textGenerator: QwenMLXTextGenerator(modelRootURL: QwenMeetingMinutesModel.root(using: store))
        )
    }

    func generate(
        from input: MeetingMinutesInput,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> MeetingMinutes {
        try Task.checkCancellation()
        let chunks = MeetingMinutesPromptBuilder.chunks(
            for: input.transcript,
            characterLimit: chunkCharacterLimit
        )
        guard !chunks.isEmpty else { throw MeetingMinutesError.emptyTranscript }

        let options = MeetingMinutesGenerationOptions()
        var evidence = [String]()
        if chunks.count == 1 {
            evidence = chunks[0]
        } else {
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let extraction = try await textGenerator.generate(
                    prompt: MeetingMinutesPromptBuilder.extractionPrompt(
                        lines: chunk,
                        title: input.title,
                        context: input.context
                    ),
                    options: options,
                    progress: { value in
                        progress((Double(index) + value) / Double(chunks.count + 1))
                    }
                )
                evidence.append(try Self.nonEmptyText(extraction))
            }
        }

        try Task.checkCancellation()
        let finalText = try await textGenerator.generate(
            prompt: MeetingMinutesPromptBuilder.synthesisPrompt(
                extractions: chunks.count == 1 ? evidence : evidence,
                title: input.title,
                context: input.context
            ),
            options: options,
            progress: { value in
                progress(chunks.count == 1 ? value : (Double(chunks.count) + value) / Double(chunks.count + 1))
            }
        )
        progress(1)

        return MeetingMinutes(
            recordingID: input.transcript.recordingID,
            sourceTranscriptMetadata: input.transcript.metadata,
            modelID: modelID,
            text: try Self.nonEmptyText(finalText),
            createdAt: dateProvider()
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

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        let container = try await loadContainer(progress: progress)
        let input = try await container.prepare(input: UserInput(prompt: prompt))
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(
                maxTokens: options.maxTokens,
                temperature: options.temperature,
                topP: 1,
                topK: 0
            )
        )

        var output = ""
        for await generation in stream {
            try Task.checkCancellation()
            if case .chunk(let chunk) = generation {
                output.append(contentsOf: chunk)
            }
        }
        return output
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

    func generate(
        prompt: String,
        options: MeetingMinutesGenerationOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        _ = prompt
        _ = options
        _ = progress
        throw MeetingMinutesError.modelNotAvailable(
            "MLXSwiftLM, Hugging Face, and Tokenizers are not linked in this build."
        )
    }
}
#endif
