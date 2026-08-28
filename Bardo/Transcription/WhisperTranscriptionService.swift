import Foundation
import OSLog
@preconcurrency import WhisperKit

enum TranscriptionStage: String, Sendable {
    case preparingModel
    case loadingModel
    case transcribing
    case saving
}

struct TranscriptionProgressSnapshot: Equatable, Sendable {
    let stage: TranscriptionStage
    let fractionCompleted: Double
}

enum TranscriptionSetupStage: String, Sendable {
    case checking
    case downloading
    case preparingLanguageSupport
    case optimizingForMac
}

struct TranscriptionSetupProgressSnapshot: Equatable, Sendable {
    let stage: TranscriptionSetupStage
    let fractionCompleted: Double
}

protocol RecordingTranscribing: Sendable {
    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript

    func warmUpIfInstalled() async
}

extension RecordingTranscribing {
    func warmUpIfInstalled() async {}
}

struct PartialTranscriptionFailure: Error, LocalizedError, Sendable {
    let transcript: Transcript
    let underlyingDescription: String

    var errorDescription: String? {
        "Transcription stopped before all audio was processed. The completed portion was preserved. \(underlyingDescription)"
    }
}

enum RecordingTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case noManagedAudio(Recording.ID)
    case combinedAudioUnavailable(Recording.ID)
    case invalidDuration
    case inputCoverageMismatch(expectedSamples: Int, actualSamples: Int)
    case decoderReturnedNoResult

    var errorDescription: String? {
        switch self {
        case .noManagedAudio(let id):
            return "Recording \(id.uuidString) has no readable managed audio to transcribe."
        case .combinedAudioUnavailable:
            return "The combined System Audio + Microphone track is unavailable. Bardo preserved the original tracks; regenerate the conversation mix before transcribing."
        case .invalidDuration:
            return "Bardo could not determine a valid audio duration for transcription."
        case .inputCoverageMismatch(let expectedSamples, let actualSamples):
            return "Bardo stopped because the audio decoder returned only \(actualSamples) of about \(expectedSamples) expected samples. The recording was not marked complete."
        case .decoderReturnedNoResult:
            return "The transcription engine finished without returning a decode result. The recording was not marked complete."
        }
    }
}

struct TranscriptionChunkPlan: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let acceptanceStart: TimeInterval
    let acceptanceEnd: TimeInterval
    let isLast: Bool
}

enum TranscriptionChunkPlanner {
    static let defaultChunkDuration: TimeInterval = 300
    static let defaultOverlap: TimeInterval = 1

    static func plans(
        duration: TimeInterval,
        chunkDuration: TimeInterval = defaultChunkDuration,
        overlap: TimeInterval = defaultOverlap
    ) -> [TranscriptionChunkPlan] {
        guard duration.isFinite,
              chunkDuration.isFinite,
              overlap.isFinite,
              duration > 0,
              chunkDuration > overlap,
              overlap >= 0 else {
            return []
        }

        var raw: [(start: TimeInterval, end: TimeInterval)] = []
        var start: TimeInterval = 0
        while start < duration {
            let end = min(duration, start + chunkDuration)
            raw.append((start, end))
            if end >= duration { break }
            start = end - overlap
        }

        return raw.enumerated().map { index, chunk in
            let previousBoundary: TimeInterval
            if index == 0 {
                previousBoundary = 0
            } else {
                let previous = raw[index - 1]
                previousBoundary = chunk.start + (previous.end - chunk.start) / 2
            }

            let isLast = index == raw.count - 1
            let nextBoundary: TimeInterval
            if isLast {
                nextBoundary = duration
            } else {
                let next = raw[index + 1]
                nextBoundary = next.start + (chunk.end - next.start) / 2
            }

            return TranscriptionChunkPlan(
                startTime: chunk.start,
                endTime: chunk.end,
                acceptanceStart: previousBoundary,
                acceptanceEnd: nextBoundary,
                isLast: isLast
            )
        }
    }
}

struct TranscriptionDecodingProfile: Equatable, Sendable {
    static let shortFormThreshold: TimeInterval = 45

    /// Bardo already owns deterministic, overlapping 5-minute chunking. Adding WhisperKit's
    /// VAD chunker on top creates a second segmentation layer that can omit ranges before the
    /// decoder ever sees them. Reliability wins here: every Bardo chunk is decoded linearly.
    let usesVAD: Bool
    let temperatureFallbackCount: Int

    static func make(duration: TimeInterval, planCount: Int) -> TranscriptionDecodingProfile {
        let isShortForm = duration.isFinite
            && duration > 0
            && duration <= shortFormThreshold
            && planCount == 1

        return TranscriptionDecodingProfile(
            usesVAD: false,
            temperatureFallbackCount: isShortForm ? 3 : 5
        )
    }
}

enum TranscriptionAudioSelection {
    static func candidates(for recording: Recording) -> [AudioAsset] {
        let isDualCapture = recording.sources.contains(.systemAudio)
            && recording.sources.contains(.microphone)
        if isDualCapture {
            return recording.audioAssets.filter { $0.role == .conversationMix }
        }
        return recording.playbackAudioAssets
    }
}

enum TranscriptionInputIntegrity {
    static let sampleRate: Double = 16_000
    static let durationTolerance: TimeInterval = 0.25

    static func expectedSamples(duration: TimeInterval) -> Int {
        max(0, Int((duration * sampleRate).rounded()))
    }

    static func validates(sampleCount: Int, requestedDuration: TimeInterval) -> Bool {
        guard sampleCount > 0, requestedDuration.isFinite, requestedDuration > 0 else { return false }
        let actualDuration = Double(sampleCount) / sampleRate
        return actualDuration + durationTolerance >= requestedDuration
    }
}

private final class TranscriptionCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

actor WhisperTranscriptionService: RecordingTranscribing {
    static let engineVersion = "1.1.0"
    static let defaultIdleUnloadNanoseconds: UInt64 = 30 * 60 * 1_000_000_000

    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "transcription.performance"
    )

    private static let sharedServiceResult: Result<WhisperTranscriptionService, Error> = Result {
        WhisperTranscriptionService(modelManager: try TranscriptionModelManager.live())
    }

    private let modelManager: TranscriptionModelManager
    private let chunkDuration: TimeInterval
    private let overlap: TimeInterval
    private let idleUnloadNanoseconds: UInt64
    private let metadataReader = AudioMetadataReader()

    private var loadedWhisper: WhisperKit?
    private var idleUnloadTask: Task<Void, Never>?

    init(
        modelManager: TranscriptionModelManager,
        chunkDuration: TimeInterval = TranscriptionChunkPlanner.defaultChunkDuration,
        overlap: TimeInterval = TranscriptionChunkPlanner.defaultOverlap,
        idleUnloadNanoseconds: UInt64 = WhisperTranscriptionService.defaultIdleUnloadNanoseconds
    ) {
        self.modelManager = modelManager
        self.chunkDuration = chunkDuration
        self.overlap = overlap
        self.idleUnloadNanoseconds = idleUnloadNanoseconds
    }

    static func live() throws -> WhisperTranscriptionService {
        try sharedServiceResult.get()
    }

    func hasInstalledModel() async -> Bool {
        (try? await modelManager.hasInstalledModel()) == true
    }

    func prepareForUse(
        progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void
    ) async throws {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        progress(.init(stage: .checking, fractionCompleted: 0))
        let wasInstalled = try await modelManager.hasInstalledModel()

        let resources = try await modelManager.ensureResourcesAvailable { fraction in
            let clamped = Self.clamped(fraction)
            if !wasInstalled, clamped < 0.9 {
                progress(
                    .init(
                        stage: .downloading,
                        fractionCompleted: Self.clamped(clamped / 0.9)
                    )
                )
            } else {
                progress(
                    .init(
                        stage: .preparingLanguageSupport,
                        fractionCompleted: Self.clamped((clamped - 0.9) / 0.1)
                    )
                )
            }
        }

        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        _ = try await engine(resources: resources, progress: { _ in })
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
        scheduleIdleUnload()
    }

    func warmUpIfInstalled() async {
        guard loadedWhisper == nil else {
            scheduleIdleUnload()
            return
        }

        do {
            guard try await modelManager.hasInstalledModel() else { return }
            let resources = try await modelManager.ensureResourcesAvailable()
            _ = try await engine(resources: resources, progress: { _ in })
            scheduleIdleUnload()
        } catch {
            Self.logger.debug("Background Whisper warm-up skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        let cancellation = TranscriptionCancellationFlag()
        return try await withTaskCancellationHandler {
            do {
                let transcript = try await transcribeInternal(
                    recording: recording,
                    store: store,
                    cancellation: cancellation,
                    progress: progress
                )
                scheduleIdleUnload()
                return transcript
            } catch {
                scheduleIdleUnload()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func transcribeInternal(
        recording: Recording,
        store: RecordingStore,
        cancellation: TranscriptionCancellationFlag,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        try checkCancellation(cancellation)

        let overallStart = ProcessInfo.processInfo.systemUptime
        let (audioURL, duration) = try await resolveAudio(recording: recording, store: store)
        let plans = TranscriptionChunkPlanner.plans(
            duration: duration,
            chunkDuration: chunkDuration,
            overlap: overlap
        )
        guard !plans.isEmpty else { throw RecordingTranscriptionError.invalidDuration }

        progress(.init(stage: .preparingModel, fractionCompleted: 0))
        let resources = try await modelManager.ensureResourcesAvailable { fraction in
            progress(.init(stage: .preparingModel, fractionCompleted: fraction))
        }
        try checkCancellation(cancellation)

        let whisper = try await engine(resources: resources, progress: progress)
        try checkCancellation(cancellation)

        let transcript = try await transcribeChunks(
            recordingID: recording.id,
            audioURL: audioURL,
            recordingDuration: duration,
            plans: plans,
            whisper: whisper,
            modelID: await modelManager.selectedModelID(),
            cancellation: cancellation,
            progress: progress
        )

        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - overallStart)
        let realTimeFactor = duration > 0 ? elapsed / duration : 0
        Self.logger.info(
            "Whisper finished audioSeconds=\(duration) elapsedSeconds=\(elapsed) rtf=\(realTimeFactor) segments=\(transcript.segments.count) coverage=complete"
        )
        return transcript
    }

    private func engine(
        resources: TranscriptionModelResources,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> WhisperKit {
        if let loadedWhisper {
            progress(.init(stage: .loadingModel, fractionCompleted: 1))
            return loadedWhisper
        }

        progress(.init(stage: .loadingModel, fractionCompleted: 0))
        let loadStart = ProcessInfo.processInfo.systemUptime
        let config = WhisperKitConfig(
            model: nil,
            modelFolder: resources.modelFolder.path,
            tokenizerFolder: resources.tokenizerFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)
        loadedWhisper = whisper
        progress(.init(stage: .loadingModel, fractionCompleted: 1))

        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - loadStart)
        Self.logger.info("Whisper Core ML load finished elapsedSeconds=\(elapsed)")
        return whisper
    }

    private func transcribeChunks(
        recordingID: Recording.ID,
        audioURL: URL,
        recordingDuration: TimeInterval,
        plans: [TranscriptionChunkPlan],
        whisper: WhisperKit,
        modelID: String,
        cancellation: TranscriptionCancellationFlag,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        let languagePreference = TranscriptionLanguagePreference.current
        let preferredLanguageCode = languagePreference.whisperLanguageCode
        var segments: [TranscriptSegment] = []
        var detectedLanguage: String?
        var processedThrough: TimeInterval = 0
        let profile = TranscriptionDecodingProfile.make(
            duration: recordingDuration,
            planCount: plans.count
        )

        for (index, plan) in plans.enumerated() {
            try checkCancellation(cancellation)

            do {
                let samples = try BoundedWhisperAudioLoader.loadSamples(
                    from: audioURL,
                    startTime: plan.startTime,
                    endTime: plan.endTime
                )
                let requestedDuration = plan.endTime - plan.startTime
                let expectedSamples = TranscriptionInputIntegrity.expectedSamples(duration: requestedDuration)
                guard TranscriptionInputIntegrity.validates(
                    sampleCount: samples.count,
                    requestedDuration: requestedDuration
                ) else {
                    throw RecordingTranscriptionError.inputCoverageMismatch(
                        expectedSamples: expectedSamples,
                        actualSamples: samples.count
                    )
                }

                let languagePolicy = TranscriptionLanguagePolicy.make(
                    preference: languagePreference,
                    lockedLanguageCode: detectedLanguage
                )
                let options = DecodingOptions(
                    // Product invariant: Bardo is a transcriber, never a speech translator.
                    task: .transcribe,
                    language: languagePolicy.languageCode,
                    temperatureFallbackCount: profile.temperatureFallbackCount,
                    usePrefillPrompt: true,
                    detectLanguage: languagePolicy.detectsLanguage,
                    skipSpecialTokens: true,
                    wordTimestamps: true,
                    windowClipTime: 0,
                    chunkingStrategy: nil
                )
                let results = try await whisper.transcribe(
                    audioArray: samples,
                    decodeOptions: options,
                    callback: { _ in
                        !cancellation.isCancelled
                    }
                )
                try checkCancellation(cancellation)
                guard !results.isEmpty else {
                    throw RecordingTranscriptionError.decoderReturnedNoResult
                }

                for result in results {
                    if detectedLanguage == nil, !result.language.isEmpty {
                        detectedLanguage = result.language
                    }
                    append(result: result, plan: plan, to: &segments)
                }

                processedThrough = plan.acceptanceEnd
                progress(.init(
                    stage: .transcribing,
                    fractionCompleted: Double(index + 1) / Double(plans.count)
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if processedThrough > 0 || !segments.isEmpty {
                    let partial = makeTranscript(
                        recordingID: recordingID,
                        languageCode: preferredLanguageCode ?? detectedLanguage,
                        segments: segments,
                        modelID: modelID,
                        sourceDuration: recordingDuration,
                        processedDuration: processedThrough,
                        completion: .partial
                    )
                    throw PartialTranscriptionFailure(
                        transcript: partial,
                        underlyingDescription: error.localizedDescription
                    )
                }
                throw error
            }
        }

        return makeTranscript(
            recordingID: recordingID,
            languageCode: preferredLanguageCode ?? detectedLanguage,
            segments: segments,
            modelID: modelID,
            sourceDuration: recordingDuration,
            processedDuration: recordingDuration,
            completion: .complete
        )
    }

    private func append(
        result: TranscriptionResult,
        plan: TranscriptionChunkPlan,
        to segments: inout [TranscriptSegment]
    ) {
        for segment in result.segments {
            let globalStart = plan.startTime + TimeInterval(segment.start)
            let globalEnd = plan.startTime + TimeInterval(segment.end)
            let midpoint = globalStart + (globalEnd - globalStart) / 2
            let accepted = midpoint >= plan.acceptanceStart
                && (plan.isLast ? midpoint <= plan.acceptanceEnd : midpoint < plan.acceptanceEnd)
            guard accepted else { continue }

            let words = (segment.words ?? []).map { word in
                TranscriptWord(
                    startTime: plan.startTime + TimeInterval(word.start),
                    endTime: plan.startTime + TimeInterval(word.end),
                    text: word.word,
                    probability: word.probability
                )
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(
                TranscriptSegment(
                    startTime: globalStart,
                    endTime: globalEnd,
                    text: text,
                    words: words
                )
            )
        }

        segments.sort {
            if $0.startTime == $1.startTime { return $0.id.uuidString < $1.id.uuidString }
            return $0.startTime < $1.startTime
        }
    }

    private func makeTranscript(
        recordingID: Recording.ID,
        languageCode: String?,
        segments: [TranscriptSegment],
        modelID: String,
        sourceDuration: TimeInterval,
        processedDuration: TimeInterval,
        completion: TranscriptionCompletion
    ) -> Transcript {
        let clampedProcessed = min(sourceDuration, max(0, processedDuration))
        return Transcript(
            recordingID: recordingID,
            languageCode: languageCode,
            segments: segments,
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: Self.engineVersion,
                modelID: modelID,
                coverage: TranscriptionCoverage(
                    completion: completion,
                    sourceDuration: sourceDuration,
                    processedDuration: clampedProcessed,
                    expectedSampleCount: TranscriptionInputIntegrity.expectedSamples(duration: sourceDuration),
                    processedSampleCount: TranscriptionInputIntegrity.expectedSamples(duration: clampedProcessed)
                )
            )
        )
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
                let metadata = try metadataReader.read(from: url)
                let duration = metadata.duration
                if duration.isFinite, duration > 0 {
                    if abs(duration - asset.metadata.duration) > 0.25 {
                        Self.logger.warning(
                            "Managed audio duration differs from manifest file=\(duration) manifest=\(asset.metadata.duration) recording=\(recording.id.uuidString, privacy: .public)"
                        )
                    }
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

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadNanoseconds
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.unloadEngineAfterIdleTimeout()
        }
    }

    private func unloadEngineAfterIdleTimeout() async {
        guard let whisper = loadedWhisper else { return }
        loadedWhisper = nil
        idleUnloadTask = nil
        await whisper.unloadModels()
    }

    private func checkCancellation(_ cancellation: TranscriptionCancellationFlag) throws {
        if cancellation.isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    nonisolated private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
