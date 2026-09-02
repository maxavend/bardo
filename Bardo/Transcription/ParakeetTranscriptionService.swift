@preconcurrency import AVFoundation
import Foundation
import OSLog
import FluidAudio

struct ParakeetModelOperations: Sendable {
    let modelsExist: @Sendable (URL) -> Bool
    let download: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    let load: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> AsrModels

    static let live = ParakeetModelOperations(
        modelsExist: { url in
            AsrModels.modelsExist(
                at: url,
                version: .v3,
                encoderPrecision: .int8
            )
        },
        download: { url, progress in
            _ = try await AsrModels.download(
                to: url,
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { update in
                    progress(update.fractionCompleted)
                }
            )
        },
        load: { url, progress in
            try await AsrModels.load(
                from: url,
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { update in
                    progress(update.fractionCompleted)
                }
            )
        }
    )
}

enum ParakeetModelManagerError: Error, LocalizedError, Equatable, Sendable {
    case incompleteModel(URL)

    var errorDescription: String? {
        switch self {
        case .incompleteModel(let url):
            return "Parakeet models are incomplete at \(url.path)."
        }
    }
}

actor ParakeetModelManager {
    private let modelRoot: URL
    private let fileManager: FileManager
    private let operations: ParakeetModelOperations
    private var modelState: ManagedModelState = .notInstalled

    init(
        modelRoot: URL,
        fileManager: FileManager = .default,
        operations: ParakeetModelOperations = .live
    ) {
        self.modelRoot = modelRoot.standardizedFileURL
        self.fileManager = fileManager
        self.operations = operations
    }

    func hasInstalledModel() async -> Bool {
        guard isPrivateRootValid() else { return false }
        return operations.modelsExist(modelRoot)
    }

    func prepareForUse(
        progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void
    ) async throws -> AsrModels {
        progress(.init(stage: .checking, fractionCompleted: 0))
        let wasComplete = await hasInstalledModel()

        if wasComplete {
            do {
                let models = try await load(progress: progress)
                modelState = .installed
                return models
            } catch {
                let decision = ModelRecoveryPolicy.decision(
                    wasComplete: true,
                    phase: .loading,
                    isCancellation: isCancellation(error),
                    errorKind: errorKind(error)
                )
                guard decision == .retryLoadAfterRepair else {
                    modelState = .failed(error.localizedDescription)
                    throw error
                }

                try reset()
                progress(.init(stage: .downloading, fractionCompleted: 0))
                try await download(progress: progress)
                try Task.checkCancellation()
                guard operations.modelsExist(modelRoot) else {
                    let error = ParakeetModelManagerError.incompleteModel(modelRoot)
                    modelState = .failed(error.localizedDescription)
                    throw error
                }

                let models = try await load(progress: progress)
                modelState = .installed
                return models
            }
        }

        do {
            progress(.init(stage: .downloading, fractionCompleted: 0))
            try await download(progress: progress)
            try Task.checkCancellation()
            guard operations.modelsExist(modelRoot) else {
                throw ParakeetModelManagerError.incompleteModel(modelRoot)
            }

            let models = try await load(progress: progress)
            modelState = .installed
            return models
        } catch {
            modelState = .failed(error.localizedDescription)
            throw error
        }
    }

    func reset() throws {
        let store = BardoModelStore(
            rootURL: modelRoot.deletingLastPathComponent(),
            fileManager: fileManager
        )
        try store.reset(.parakeet)
        modelState = .notInstalled
    }

    private func download(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        modelState = .downloading(0)
        try await operations.download(modelRoot) { fraction in
            progress(.init(stage: .downloading, fractionCompleted: Self.clamped(fraction)))
        }
        modelState = .preparing(1)
    }

    private func load(
        progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void
    ) async throws -> AsrModels {
        modelState = .preparing(0)
        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        let models = try await operations.load(modelRoot) { fraction in
            progress(.init(stage: .optimizingForMac, fractionCompleted: Self.clamped(fraction)))
        }
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
        return models
    }

    private func isPrivateRootValid() -> Bool {
        modelRoot.resolvingSymlinksInPath() == modelRoot
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    private func errorKind(_ error: Error) -> ModelErrorKind {
        if error is DownloadError {
            return .network
        }
        return .load
    }

    private static func clamped(_ fraction: Double) -> Double {
        min(1, max(0, fraction))
    }
}

struct ParakeetTokenTiming: Equatable, Sendable {
    let token: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float

    init(token: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float) {
        self.token = token
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

struct ParakeetTranscriptionOutput: Equatable, Sendable {
    let text: String
    let duration: TimeInterval
    let tokenTimings: [ParakeetTokenTiming]

    init(text: String, duration: TimeInterval, tokenTimings: [ParakeetTokenTiming]) {
        self.text = text
        self.duration = duration
        self.tokenTimings = tokenTimings
    }

    init(result: ASRResult) {
        self.init(
            text: result.text,
            duration: result.duration,
            tokenTimings: result.tokenTimings?.map {
                ParakeetTokenTiming(
                    token: $0.token,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    confidence: $0.confidence
                )
            } ?? []
        )
    }
}

enum ParakeetTranscriptNormalizer {
    static func transcript(
        recordingID: Recording.ID,
        output: ParakeetTranscriptionOutput,
        selection: TranscriptionSelection
    ) throws -> Transcript {
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw RecordingTranscriptionError.emptyTranscription
        }
        guard output.duration.isFinite, output.duration > 0 else {
            throw RecordingTranscriptionError.invalidDuration
        }

        return Transcript(
            recordingID: recordingID,
            segments: [
                TranscriptSegment(
                    startTime: 0,
                    endTime: output.duration,
                    text: text,
                    words: words(from: output.tokenTimings)
                )
            ],
            metadata: TranscriptMetadata(
                engine: "FluidAudio",
                engineVersion: "0.15.6",
                modelID: selection.modelID,
                selection: selection
            )
        )
    }

    private static func words(from tokenTimings: [ParakeetTokenTiming]) -> [TranscriptWord] {
        var result: [TranscriptWord] = []
        var currentText = ""
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        var currentConfidences: [Float] = []

        func flush() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let probability = currentConfidences.isEmpty
                ? nil
                : currentConfidences.reduce(0, +) / Float(currentConfidences.count)
            result.append(
                TranscriptWord(
                    startTime: currentStart,
                    endTime: currentEnd,
                    text: text,
                    probability: probability
                )
            )
        }

        for timing in tokenTimings {
            guard !timing.token.isEmpty,
                  timing.token != "<blank>",
                  timing.token != "<pad>"
            else { continue }

            let beginsWord = timing.token.hasPrefix("▁")
                || timing.token.first == " "
                || currentText.isEmpty
            let normalizedToken = timing.token.replacingOccurrences(of: "▁", with: " ")

            if beginsWord, !currentText.isEmpty {
                flush()
                currentText = ""
                currentConfidences = []
            }
            if beginsWord {
                currentStart = timing.startTime
            }
            currentText += normalizedToken
            currentEnd = timing.endTime
            currentConfidences.append(timing.confidence)
        }
        flush()
        return result
    }
}

actor ParakeetTranscriptionService: RecordingTranscribing {
    static let engineVersion = "0.15.6"
    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "transcription.parakeet"
    )
    private static let sharedServiceResult: Result<ParakeetTranscriptionService, Error> = Result {
        let store = try BardoModelStore.live()
        return ParakeetTranscriptionService(
            modelManager: ParakeetModelManager(modelRoot: store.root(for: .parakeet))
        )
    }

    private let modelManager: ParakeetModelManager
    private var loadedManager: AsrManager?

    init(modelManager: ParakeetModelManager) {
        self.modelManager = modelManager
    }

    static func live() throws -> ParakeetTranscriptionService {
        try sharedServiceResult.get()
    }

    func hasInstalledModel() async -> Bool {
        await modelManager.hasInstalledModel()
    }

    func warmUpIfInstalled() async {
        guard loadedManager == nil else { return }
        do {
            guard await modelManager.hasInstalledModel() else { return }
            let models = try await modelManager.prepareForUse { _ in }
            _ = try await engine(models: models)
        } catch {
            Self.logger.debug("Background Parakeet warm-up skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        let (audioURL, _) = try await resolveAudio(recording: recording, store: store)
        try Task.checkCancellation()

        progress(.init(stage: .preparingModel, fractionCompleted: 0))
        let models = try await modelManager.prepareForUse { snapshot in
            progress(.init(stage: .preparingModel, fractionCompleted: snapshot.fractionCompleted))
        }
        try Task.checkCancellation()

        progress(.init(stage: .loadingModel, fractionCompleted: 0))
        let manager = try await engine(models: models)
        progress(.init(stage: .loadingModel, fractionCompleted: 1))
        progress(.init(stage: .transcribing, fractionCompleted: 0))

        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        try Task.checkCancellation()
        progress(.init(stage: .transcribing, fractionCompleted: 1))

        return try ParakeetTranscriptNormalizer.transcript(
            recordingID: recording.id,
            output: ParakeetTranscriptionOutput(result: result),
            selection: TranscriptionSelection(
                preset: .instant,
                backend: .parakeet,
                modelID: TranscriptionBackend.parakeetModelID
            )
        )
    }

    private func engine(models: AsrModels) async throws -> AsrManager {
        if let loadedManager {
            return loadedManager
        }

        let manager = AsrManager(config: .default, models: models)
        guard await manager.isAvailable else {
            throw RecordingTranscriptionError.emptyTranscription
        }
        loadedManager = manager
        return manager
    }

    private func resolveAudio(
        recording: Recording,
        store: RecordingStore
    ) async throws -> (URL, TimeInterval) {
        let candidates = TranscriptionAudioSelection.candidates(for: recording)
        let isDualCapture = recording.sources.contains(.systemAudio)
            && recording.sources.contains(.microphone)

        guard !isDualCapture || !candidates.isEmpty else {
            throw RecordingTranscriptionError.combinedAudioUnavailable(recording.id)
        }

        for asset in candidates {
            do {
                let url = try await store.managedAudioURL(
                    recordingID: recording.id,
                    audioAssetID: asset.id
                )
                let duration = asset.metadata.duration
                if duration.isFinite, duration > 0 {
                    return (url, duration)
                }
            } catch {
                continue
            }
        }

        if isDualCapture {
            throw RecordingTranscriptionError.combinedAudioUnavailable(recording.id)
        }
        throw RecordingTranscriptionError.noManagedAudio(recording.id)
    }
}
