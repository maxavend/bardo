import CoreML
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

struct TranscriptionLiveSnapshot: Equatable, Sendable {
    let recordingID: Recording.ID
    let segments: [TranscriptSegment]
    let provisionalText: String
    let processedAudioTime: TimeInterval
    let audioDuration: TimeInterval

    var fractionCompleted: Double {
        guard audioDuration.isFinite, audioDuration > 0 else { return 0 }
        return min(1, max(0, processedAudioTime / audioDuration))
    }

    static func empty(recordingID: Recording.ID, audioDuration: TimeInterval) -> TranscriptionLiveSnapshot {
        TranscriptionLiveSnapshot(
            recordingID: recordingID,
            segments: [],
            provisionalText: "",
            processedAudioTime: 0,
            audioDuration: audioDuration
        )
    }
}

enum TranscriptionSetupStage: String, Sendable {
    case checking
    case downloading
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

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void,
        liveUpdate: @escaping @Sendable (TranscriptionLiveSnapshot) -> Void
    ) async throws -> Transcript

    func warmUpIfInstalled() async
}

extension RecordingTranscribing {
    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void,
        liveUpdate: @escaping @Sendable (TranscriptionLiveSnapshot) -> Void
    ) async throws -> Transcript {
        try await transcribe(recording: recording, store: store, progress: progress)
    }

    func warmUpIfInstalled() async {}
}

enum RecordingTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case noManagedAudio(Recording.ID)
    case combinedAudioUnavailable(Recording.ID)
    case invalidDuration
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .noManagedAudio(let id):
            return "Recording \(id.uuidString) has no readable managed audio to transcribe."
        case .combinedAudioUnavailable:
            return "The combined System Audio + Microphone track is unavailable. Bardo preserved the original tracks; regenerate the conversation mix before transcribing."
        case .invalidDuration:
            return "Bardo could not determine a valid audio duration for transcription."
        case .emptyTranscription:
            return "WhisperKit completed without producing any transcript segments."
        }
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

private final class TranscriptionLiveRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastEmissionUptime: TimeInterval?

    init(minimumInterval: TimeInterval = 0.12) {
        self.minimumInterval = minimumInterval
    }

    func shouldEmit(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let lastEmissionUptime else {
            self.lastEmissionUptime = now
            return true
        }
        guard now - lastEmissionUptime >= minimumInterval else {
            return false
        }
        self.lastEmissionUptime = now
        return true
    }
}

final class TranscriptionLiveBuffer: @unchecked Sendable {
    private struct SegmentKey: Hashable {
        let startMilliseconds: Int
        let endMilliseconds: Int

        init(_ segment: TranscriptSegment) {
            startMilliseconds = Int((segment.startTime * 1_000).rounded())
            endMilliseconds = Int((segment.endTime * 1_000).rounded())
        }
    }

    private let lock = NSLock()
    private let recordingID: Recording.ID
    private let audioDuration: TimeInterval
    private var segmentsByKey: [SegmentKey: TranscriptSegment] = [:]
    private var provisionalText = ""

    init(recordingID: Recording.ID, audioDuration: TimeInterval) {
        self.recordingID = recordingID
        self.audioDuration = audioDuration
    }

    func updateProvisionalText(_ text: String) -> TranscriptionLiveSnapshot {
        lock.lock()
        defer { lock.unlock() }

        provisionalText = segmentsByKey.isEmpty
            ? TranscriptTextSanitizer.sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return makeSnapshot()
    }

    func merge(_ segments: [TranscriptSegment]) -> TranscriptionLiveSnapshot {
        lock.lock()
        defer { lock.unlock() }

        for segment in segments {
            let key = SegmentKey(segment)
            let existingID = segmentsByKey[key]?.id ?? segment.id
            segmentsByKey[key] = TranscriptSegment(
                id: existingID,
                startTime: segment.startTime,
                endTime: segment.endTime,
                speakerID: segment.speakerID,
                text: segment.text,
                words: segment.words,
                editedText: segment.editedText
            )
        }

        if !segmentsByKey.isEmpty {
            provisionalText = ""
        }
        return makeSnapshot()
    }

    func snapshot() -> TranscriptionLiveSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot()
    }

    private func makeSnapshot() -> TranscriptionLiveSnapshot {
        let sortedSegments = segmentsByKey.values.sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
        let processedAudioTime = sortedSegments.map(\.endTime).max() ?? 0

        return TranscriptionLiveSnapshot(
            recordingID: recordingID,
            segments: sortedSegments,
            provisionalText: provisionalText,
            processedAudioTime: processedAudioTime,
            audioDuration: audioDuration
        )
    }
}

struct WhisperTranscriptionMetrics: Equatable, Sendable {
    let audioSeconds: TimeInterval
    let modelPreparationSeconds: TimeInterval
    let modelLoadSeconds: TimeInterval
    let inferenceSeconds: TimeInterval
    let endToEndSeconds: TimeInterval
    let timeToFirstTextSeconds: TimeInterval?
    let asrSeconds: TimeInterval
    let asrRealTimeFactor: Double
    let endToEndRealTimeFactor: Double
    let segmentCount: Int
    let wordCount: Int
    let incrementalChunkDurationSeconds: Double
    let maxBufferedChunks: Int
    let workerCount: Int
    let fallbackCount: Int
    let vadWindowCount: Int
    let peakResidentMemoryBytes: UInt64?
    let memoryPressureOccurred: Bool
    let thermalStateAtStart: WhisperThermalLevel
    let worstThermalState: WhisperThermalLevel
    let thermalStateAtEnd: WhisperThermalLevel
    let progressSamples: [WhisperRuntimeSample]
}

actor WhisperTranscriptionService: RecordingTranscribing {
    static let engineVersion = "1.1.0"
    static let defaultIdleUnloadNanoseconds: UInt64 = 30 * 60 * 1_000_000_000

    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "transcription.performance"
    )

    private static let signposter = OSSignposter(
        subsystem: "com.maxavend.bardo",
        category: "transcription.performance"
    )

    private static let sharedServiceResult: Result<WhisperTranscriptionService, Error> = Result {
        WhisperTranscriptionService(modelManager: try TranscriptionModelManager.live())
    }

    private let modelManager: TranscriptionModelManager
    private let performanceProfile: WhisperPerformanceProfile
    private let idleUnloadNanoseconds: UInt64

    private var loadedWhisper: WhisperKit?
    private var idleUnloadTask: Task<Void, Never>?
    private(set) var lastMetrics: WhisperTranscriptionMetrics?

    init(
        modelManager: TranscriptionModelManager,
        performanceProfile: WhisperPerformanceProfile = WhisperPerformanceProfile(),
        idleUnloadNanoseconds: UInt64 = WhisperTranscriptionService.defaultIdleUnloadNanoseconds
    ) {
        self.modelManager = modelManager
        self.performanceProfile = performanceProfile
        self.idleUnloadNanoseconds = idleUnloadNanoseconds
    }

    static func live() throws -> WhisperTranscriptionService {
        try sharedServiceResult.get()
    }

    func hasInstalledModel() async -> Bool {
        (try? await modelManager.hasInstalledModel()) == true
    }

    func reset() async throws {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        if let loadedWhisper {
            self.loadedWhisper = nil
            await loadedWhisper.unloadModels()
        }
        try await modelManager.reset()
    }

    func prepareForUse(
        progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void
    ) async throws {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        progress(.init(stage: .checking, fractionCompleted: 0))
        progress(.init(stage: .downloading, fractionCompleted: 0))
        var resources = try await modelManager.ensureResourcesAvailable { fraction in
            progress(.init(stage: .downloading, fractionCompleted: Self.clamped(fraction)))
        }
        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        do {
            _ = try await engine(resources: resources, progress: { _ in })
        } catch {
            // A complete-looking Core ML cache can still be stale or corrupted after an
            // interrupted update. Repair only that private root and retry once.
            loadedWhisper = nil
            try await modelManager.reset()
            progress(.init(stage: .downloading, fractionCompleted: 0))
            resources = try await modelManager.ensureResourcesAvailable { fraction in
                progress(.init(stage: .downloading, fractionCompleted: Self.clamped(fraction)))
            }
            _ = try await engine(resources: resources, progress: { _ in })
        }
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
        try await transcribe(
            recording: recording,
            store: store,
            progress: progress,
            liveUpdate: { _ in }
        )
    }

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void,
        liveUpdate: @escaping @Sendable (TranscriptionLiveSnapshot) -> Void
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
                    progress: progress,
                    liveUpdate: liveUpdate
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
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void,
        liveUpdate: @escaping @Sendable (TranscriptionLiveSnapshot) -> Void
    ) async throws -> Transcript {
        try checkCancellation(cancellation)

        let overallStart = ProcessInfo.processInfo.systemUptime
        let initialThermalState = WhisperThermalLevel(ProcessInfo.processInfo.thermalState)
        let runtimeProbe = WhisperPerformanceProfile.diagnosticsEnabled()
            ? WhisperRuntimeProbe()
            : nil
        runtimeProbe?.start()
        var runtimeProbeStopped = false
        defer {
            if !runtimeProbeStopped {
                _ = runtimeProbe?.stop()
            }
        }

        let (audioURL, duration) = try await resolveAudio(recording: recording, store: store)
        guard duration.isFinite, duration > 0 else {
            throw RecordingTranscriptionError.invalidDuration
        }

        progress(.init(stage: .preparingModel, fractionCompleted: 0))
        let (resources, modelPreparationSeconds) = try await measure("WhisperModelPreparation") {
            try await modelManager.ensureResourcesAvailable { fraction in
                progress(.init(stage: .preparingModel, fractionCompleted: Self.clamped(fraction)))
            }
        }
        try checkCancellation(cancellation)

        let (whisper, modelLoadSeconds) = try await measure("WhisperModelLoad") {
            do {
                return try await engine(resources: resources, progress: progress)
            } catch {
                loadedWhisper = nil
                try await modelManager.reset()
                let repairedResources = try await modelManager.ensureResourcesAvailable { fraction in
                    progress(.init(stage: .preparingModel, fractionCompleted: Self.clamped(fraction)))
                }
                return try await engine(resources: repairedResources, progress: progress)
            }
        }

        try checkCancellation(cancellation)
        progress(.init(stage: .transcribing, fractionCompleted: 0))

        let options = DecodingOptions(
            temperatureFallbackCount: performanceProfile.temperatureFallbackCount,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            wordTimestamps: true,
            concurrentWorkerCount: performanceProfile.concurrentWorkerCount,
            chunkingStrategy: performanceProfile.usesVAD ? .vad : nil
        )
        let audioInputOptions = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental(
                chunkDurationSeconds: performanceProfile.incrementalChunkDurationSeconds,
                maxBufferedChunks: performanceProfile.maxBufferedChunks
            )
        )
        let liveBuffer = TranscriptionLiveBuffer(
            recordingID: recording.id,
            audioDuration: duration
        )
        let provisionalRateLimiter = TranscriptionLiveRateLimiter()
        liveUpdate(liveBuffer.snapshot())

        let previousSegmentDiscoveryCallback = whisper.segmentDiscoveryCallback
        whisper.segmentDiscoveryCallback = { discoveredSegments in
            let converted = discoveredSegments.compactMap { segment -> TranscriptSegment? in
                let text = TranscriptTextSanitizer.sanitize(segment.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                let words = (segment.words ?? []).map {
                    TranscriptWord(
                        startTime: TimeInterval($0.start),
                        endTime: TimeInterval($0.end),
                        text: $0.word,
                        probability: $0.probability
                    )
                }

                return TranscriptSegment(
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    text: text,
                    words: words
                )
            }

            guard !converted.isEmpty else { return }
            runtimeProbe?.markFirstText()
            let snapshot = liveBuffer.merge(converted)
            runtimeProbe?.markProgress(processedAudioSeconds: snapshot.processedAudioTime)
            liveUpdate(snapshot)
            progress(.init(stage: .transcribing, fractionCompleted: snapshot.fractionCompleted))
        }
        defer {
            whisper.segmentDiscoveryCallback = previousSegmentDiscoveryCallback
        }

        let (results, inferenceSeconds) = try await measure("WhisperInference") {
            try await whisper.transcribe(
                audioPath: audioURL.path,
                audioInputOptions: audioInputOptions,
                decodeOptions: options,
                callback: { update in
                    if cancellation.isCancelled {
                        return false
                    }

                    let snapshot = liveBuffer.updateProvisionalText(update.text)
                    if !snapshot.provisionalText.isEmpty {
                        runtimeProbe?.markFirstText()
                    }
                    if snapshot.segments.isEmpty,
                       !snapshot.provisionalText.isEmpty,
                       provisionalRateLimiter.shouldEmit() {
                        liveUpdate(snapshot)
                    }
                    return true
                }
            )
        }

        try checkCancellation(cancellation)
        progress(.init(stage: .transcribing, fractionCompleted: 1))

        let segments = results.flatMap { result in
            result.segments.compactMap { segment -> TranscriptSegment? in
                let words = (segment.words ?? []).map {
                    TranscriptWord(
                        startTime: TimeInterval($0.start),
                        endTime: TimeInterval($0.end),
                        text: $0.word,
                        probability: $0.probability
                    )
                }
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    text: text,
                    words: words
                )
            }
        }.sorted {
            if $0.startTime == $1.startTime { return $0.id.uuidString < $1.id.uuidString }
            return $0.startTime < $1.startTime
        }
        guard !segments.isEmpty else { throw RecordingTranscriptionError.emptyTranscription }

        let language = results.lazy.map(\.language).first { !$0.isEmpty }
        let selection = await modelManager.selectedSelection()
        let transcript = Transcript(
            recordingID: recording.id,
            languageCode: language,
            segments: segments,
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: Self.engineVersion,
                modelID: selection.modelID,
                selection: selection
            )
        )

        let endToEndSeconds = max(0, ProcessInfo.processInfo.systemUptime - overallStart)
        let timings = results.map(\.timings)
        let fallbackCount = Int(timings.reduce(0) { $0 + $1.totalDecodingFallbacks })
        let windowCount = Int(timings.reduce(0) { $0 + $1.totalDecodingWindows })

        let runtimeSnapshot = runtimeProbe?.stop()
        runtimeProbeStopped = true
        let endThermalState = WhisperThermalLevel(ProcessInfo.processInfo.thermalState)
        let peakMemory = runtimeSnapshot?.peakResidentMemoryBytes ?? 0
        let timeToFirstText = runtimeSnapshot?.timeToFirstTextSeconds ?? -1
        let memoryPressureOccurred = runtimeSnapshot?.memoryPressureOccurred ?? false
        let startThermalState = runtimeSnapshot?.thermalStateAtStart ?? initialThermalState
        let worstThermalState = runtimeSnapshot?.worstThermalState
            ?? WhisperThermalLevel.worse(initialThermalState, endThermalState)

        lastMetrics = WhisperTranscriptionMetrics(
            audioSeconds: duration,
            modelPreparationSeconds: modelPreparationSeconds,
            modelLoadSeconds: modelLoadSeconds,
            inferenceSeconds: inferenceSeconds,
            endToEndSeconds: endToEndSeconds,
            timeToFirstTextSeconds: runtimeSnapshot?.timeToFirstTextSeconds,
            asrSeconds: inferenceSeconds,
            asrRealTimeFactor: inferenceSeconds / duration,
            endToEndRealTimeFactor: endToEndSeconds / duration,
            segmentCount: transcript.segments.count,
            wordCount: transcript.segments.reduce(0) { $0 + $1.words.count },
            incrementalChunkDurationSeconds: performanceProfile.incrementalChunkDurationSeconds,
            maxBufferedChunks: performanceProfile.maxBufferedChunks,
            workerCount: performanceProfile.concurrentWorkerCount,
            fallbackCount: fallbackCount,
            vadWindowCount: windowCount,
            peakResidentMemoryBytes: runtimeSnapshot?.peakResidentMemoryBytes,
            memoryPressureOccurred: memoryPressureOccurred,
            thermalStateAtStart: startThermalState,
            worstThermalState: worstThermalState,
            thermalStateAtEnd: runtimeSnapshot?.thermalStateAtEnd ?? endThermalState,
            progressSamples: runtimeSnapshot?.progressSamples ?? []
        )

        Self.logger.info(
            "Whisper metrics audioSeconds=\(duration) modelPreparationSeconds=\(modelPreparationSeconds) modelLoadSeconds=\(modelLoadSeconds) inferenceSeconds=\(inferenceSeconds) endToEndSeconds=\(endToEndSeconds) TTFT=\(timeToFirstText) ASR_RTF=\(inferenceSeconds / duration) E2E_RTF=\(endToEndSeconds / duration) peakResidentBytes=\(peakMemory) memoryPressure=\(memoryPressureOccurred) thermalStart=\(startThermalState.rawValue, privacy: .public) thermalWorst=\(worstThermalState.rawValue, privacy: .public) thermalEnd=\((runtimeSnapshot?.thermalStateAtEnd ?? endThermalState).rawValue, privacy: .public) segments=\(transcript.segments.count) words=\(transcript.segments.reduce(0) { $0 + $1.words.count }) workers=\(self.performanceProfile.concurrentWorkerCount) incrementalChunkSeconds=\(self.performanceProfile.incrementalChunkDurationSeconds) bufferedChunks=\(self.performanceProfile.maxBufferedChunks) fallbackCount=\(fallbackCount) vadWindows=\(windowCount)"
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
        let config = WhisperKitConfig(
            model: nil,
            modelFolder: resources.modelFolder.path,
            tokenizerFolder: resources.tokenizerFolder,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)
        loadedWhisper = whisper
        progress(.init(stage: .loadingModel, fractionCompleted: 1))
        return whisper
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
                let url = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
                let duration = asset.metadata.duration
                if duration.isFinite, duration > 0 { return (url, duration) }
            } catch {
                continue
            }
        }

        if isDualCapture { throw RecordingTranscriptionError.combinedAudioUnavailable(recording.id) }
        throw RecordingTranscriptionError.noManagedAudio(recording.id)
    }

    func unloadForDiagnostics() async {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard let whisper = loadedWhisper else { return }
        loadedWhisper = nil
        await whisper.unloadModels()
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadNanoseconds
        idleUnloadTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.unloadEngineAfterIdleTimeout()
        }
    }

    private func unloadEngineAfterIdleTimeout() async {
        guard let whisper = loadedWhisper else { return }
        loadedWhisper = nil
        idleUnloadTask = nil
        await whisper.unloadModels()
    }

    private func measure<T>(
        _ name: StaticString,
        operation: () async throws -> T
    ) async rethrows -> (T, TimeInterval) {
        let signpost = Self.signposter.beginInterval(name)
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            Self.signposter.endInterval(name, signpost)
        }
        let value = try await operation()
        return (value, max(0, ProcessInfo.processInfo.systemUptime - startedAt))
    }

    private func checkCancellation(_ cancellation: TranscriptionCancellationFlag) throws {
        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
    }

    nonisolated private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
