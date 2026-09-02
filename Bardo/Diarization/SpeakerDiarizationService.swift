import Foundation
import OSLog
@preconcurrency import SpeakerKit
@preconcurrency import ArgmaxCore

enum DiarizationStage: String, Sendable {
    case preparingModel
    case loadingModel
    case diarizing
    case saving
}

struct DiarizationProgressSnapshot: Equatable, Sendable {
    let stage: DiarizationStage
    let fractionCompleted: Double
}

enum DiarizationSetupStage: String, Sendable {
    case downloading
    case optimizingForMac
}

struct DiarizationSetupProgressSnapshot: Equatable, Sendable {
    let stage: DiarizationSetupStage
    let fractionCompleted: Double
}

protocol SpeakerDiarizationEngine: AnyObject, Sendable {
    var isLoaded: Bool { get }

    func downloadModels(
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws

    func loadModels() async throws

    func diarize(
        audioArray: [Float],
        options: (any DiarizationOptions)?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DiarizationResult
}

/// Adapts SpeakerKit's concrete class to the narrow interface used by Bardo.
///
/// SpeakerKitDiarizer also inherits an overload of `downloadModels` from
/// ArgmaxCore.ModelManager. Keeping the overload resolution inside this
/// adapter prevents that library detail from leaking into Bardo's recovery
/// and test abstractions.
final class SpeakerKitDiarizationEngineAdapter: SpeakerDiarizationEngine {
    private let base: SpeakerKitDiarizer

    init(base: SpeakerKitDiarizer) {
        self.base = base
    }

    var isLoaded: Bool {
        base.isLoaded
    }

    func downloadModels(
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws {
        // SpeakerKitDiarizer exposes an overload with the same label as its
        // inherited ModelManager method. The inherited implementation is the
        // one that accepts progress callbacks and is what the subclass
        // overload delegates to; the upcast makes that choice explicit.
        let manager: ModelManager = base
        try await manager.downloadModels(progressCallback: progressCallback)
    }

    func loadModels() async throws {
        try await base.loadModels()
    }

    func diarize(
        audioArray: [Float],
        options: (any DiarizationOptions)?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DiarizationResult {
        try await base.diarize(
            audioArray: audioArray,
            options: options,
            progressCallback: progressCallback
        )
    }
}

protocol RecordingDiarizing: Sendable {
    func diarize(
        recording: Recording,
        transcript: Transcript,
        store: RecordingStore,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> Transcript
}

enum RecordingDiarizationError: Error, LocalizedError, Equatable, Sendable {
    case noManagedAudio(Recording.ID)
    case combinedAudioUnavailable(Recording.ID)
    case invalidDuration
    case noSpeakerActivity
    case speakerModelsNotLoaded

    var errorDescription: String? {
        switch self {
        case .noManagedAudio(let id):
            return "Recording \(id.uuidString) has no readable managed audio to diarize."
        case .combinedAudioUnavailable:
            return "The combined System Audio + Microphone track is unavailable. Bardo preserved the original tracks; regenerate the conversation mix before identifying speakers."
        case .invalidDuration:
            return "Bardo could not determine a valid audio duration for speaker identification."
        case .noSpeakerActivity:
            return "SpeakerKit completed without finding any speaker activity."
        case .speakerModelsNotLoaded:
            return "Bardo could not load the private SpeakerKit models. Reset the SpeakerKit models and download them again."
        }
    }
}

struct DiarizationInterval: Equatable, Sendable {
    let speakerIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum TranscriptSpeakerAligner {
    static func applying(
        intervals: [DiarizationInterval],
        to transcript: Transcript,
        metadata: DiarizationMetadata
    ) throws -> Transcript {
        let validIntervals = intervals
            .filter {
                $0.speakerIndex >= 0
                    && $0.startTime.isFinite
                    && $0.endTime.isFinite
                    && $0.endTime > $0.startTime
            }
            .sorted {
                if $0.startTime == $1.startTime {
                    if $0.endTime == $1.endTime { return $0.speakerIndex < $1.speakerIndex }
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }

        guard !validIntervals.isEmpty else {
            throw RecordingDiarizationError.noSpeakerActivity
        }

        let speakerOrder = orderedSpeakerIndices(from: validIntervals)
        let speakers = speakerOrder.map { _ in Speaker() }
        let speakerIDs = Dictionary(
            uniqueKeysWithValues: zip(speakerOrder, speakers.map(\.id))
        )

        var updated = transcript
        updated.speakers = speakers
        updated.diarizationMetadata = metadata

        for index in updated.segments.indices {
            let segment = updated.segments[index]
            let speakerIndex = bestSpeakerIndex(for: segment, intervals: validIntervals)
            updated.segments[index].speakerID = speakerIndex.flatMap { speakerIDs[$0] }
        }

        return updated
    }

    private static func orderedSpeakerIndices(from intervals: [DiarizationInterval]) -> [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for interval in intervals where seen.insert(interval.speakerIndex).inserted {
            ordered.append(interval.speakerIndex)
        }
        return ordered
    }

    private static func bestSpeakerIndex(
        for segment: TranscriptSegment,
        intervals: [DiarizationInterval]
    ) -> Int? {
        var scores: [Int: TimeInterval] = [:]

        if !segment.words.isEmpty {
            for word in segment.words {
                accumulateScores(
                    startTime: word.startTime,
                    endTime: word.endTime,
                    intervals: intervals,
                    into: &scores
                )
            }
        }

        if scores.values.allSatisfy({ $0 <= 0 }) {
            accumulateScores(
                startTime: segment.startTime,
                endTime: segment.endTime,
                intervals: intervals,
                into: &scores
            )
        }

        return scores
            .filter { $0.value > 0 }
            .max {
                if $0.value == $1.value { return $0.key > $1.key }
                return $0.value < $1.value
            }?
            .key
    }

    private static func accumulateScores(
        startTime: TimeInterval,
        endTime: TimeInterval,
        intervals: [DiarizationInterval],
        into scores: inout [Int: TimeInterval]
    ) {
        guard startTime.isFinite, endTime.isFinite, endTime >= startTime else { return }

        if endTime == startTime {
            let midpoint = startTime
            for interval in intervals where midpoint >= interval.startTime && midpoint <= interval.endTime {
                scores[interval.speakerIndex, default: 0] += 0.000_001
            }
            return
        }

        for interval in intervals {
            let overlap = max(0, min(endTime, interval.endTime) - max(startTime, interval.startTime))
            if overlap > 0 {
                scores[interval.speakerIndex, default: 0] += overlap
            }
        }
    }
}

actor SpeakerDiarizationService: RecordingDiarizing {
    static let engineVersion = "1.1.0"
    static let modelID = "pyannote-v3+plda-v4"

    private static let requiredModelNames: Set<String> = [
        "SpeakerSegmenter",
        "SpeakerEmbedderPreprocessor",
        "SpeakerEmbedder",
        "PldaProjector"
    ]

    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "diarization.performance"
    )

    private static let sharedServiceResult: Result<SpeakerDiarizationService, Error> = Result {
        SpeakerDiarizationService(
            modelStore: try BardoModelStore.live(),
            operations: .live
        )
    }

    private let modelStore: BardoModelStore
    private let modelRoot: URL
    private let operations: SpeakerDiarizationOperations
    private var loadedDiarizer: (any SpeakerDiarizationEngine)?
    private var modelState: ManagedModelState = .notInstalled

    init(
        modelStore: BardoModelStore,
        operations: SpeakerDiarizationOperations = .live
    ) {
        self.modelStore = modelStore
        self.modelRoot = modelStore.root(for: .speakerKit).standardizedFileURL
        self.operations = operations
    }

    static func live() throws -> SpeakerDiarizationService {
        try sharedServiceResult.get()
    }

    func hasInstalledModels() async -> Bool {
        if let loadedDiarizer, loadedDiarizer.isLoaded {
            modelState = .installed
            return true
        }

        guard hasCompleteModelCache() else {
            modelState = .notInstalled
            return false
        }

        do {
            let diarizer = makeEngine(allowsDownload: false)
            try Task.checkCancellation()
            modelState = .preparing(0)
            try await diarizer.loadModels()
            try Task.checkCancellation()
            guard diarizer.isLoaded else {
                throw RecordingDiarizationError.speakerModelsNotLoaded
            }
            loadedDiarizer = diarizer
            modelState = .installed
            return true
        } catch {
            loadedDiarizer = nil
            modelState = .failed(error.localizedDescription)
            return false
        }
    }

    func warmUpIfInstalled() async {
        guard hasCompleteModelCache() else {
            modelState = .notInstalled
            return
        }

        do {
            try await prepareForUse { _ in }
        } catch {
            modelState = .failed(error.localizedDescription)
            Self.logger.debug("Background speaker warm-up skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prepareForUse(
        progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void
    ) async throws {
        try Task.checkCancellation()
        try ensureModelDirectory()

        if let loadedDiarizer, loadedDiarizer.isLoaded {
            modelState = .installed
            progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
            return
        }

        let wasComplete = hasCompleteModelCache()
        do {
            if wasComplete {
                do {
                    try await loadExistingModels(progress: progress)
                    return
                } catch {
                    let decision = Self.recoveryDecision(
                        wasComplete: true,
                        phase: .loading,
                        isCancellation: Self.isCancellation(error),
                        errorKind: Self.errorKind(error)
                    )
                    guard decision == .retryLoadAfterRepair else {
                        modelState = .failed(error.localizedDescription)
                        throw error
                    }

                    // Drop invalid Core ML state before removing its files and
                    // before creating the repair engine.
                    loadedDiarizer = nil
                    try reset()
                    try Task.checkCancellation()
                    try await downloadAndLoadModels(progress: progress, allowsDownload: true)
                    return
                }
            }

            try await downloadAndLoadModels(progress: progress, allowsDownload: true)
        } catch {
            loadedDiarizer = nil
            modelState = .failed(error.localizedDescription)
            throw error
        }
    }

    func state() -> ManagedModelState {
        modelState
    }

    func reset() throws {
        loadedDiarizer = nil
        try modelStore.reset(.speakerKit)
        modelState = .notInstalled
    }

    nonisolated static func recoveryDecision(
        wasComplete: Bool,
        phase: ModelOperationPhase,
        isCancellation: Bool,
        errorKind: ModelErrorKind
    ) -> ModelRecoveryDecision {
        ModelRecoveryPolicy.decision(
            wasComplete: wasComplete,
            phase: phase,
            isCancellation: isCancellation,
            errorKind: errorKind
        )
    }

    func diarize(
        recording: Recording,
        transcript: Transcript,
        store: RecordingStore,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> Transcript {
        try Task.checkCancellation()
        let overallStart = ProcessInfo.processInfo.systemUptime
        let (audioURL, duration) = try await resolveAudio(recording: recording, store: store)
        guard duration.isFinite, duration > 0 else {
            throw RecordingDiarizationError.invalidDuration
        }

        try await prepareForUse { snapshot in
            let stage: DiarizationStage
            switch snapshot.stage {
            case .downloading:
                stage = .preparingModel
            case .optimizingForMac:
                stage = .loadingModel
            }
            progress(.init(stage: stage, fractionCompleted: snapshot.fractionCompleted))
        }
        guard let diarizer = loadedDiarizer, diarizer.isLoaded else {
            throw RecordingDiarizationError.speakerModelsNotLoaded
        }

        progress(.init(stage: .diarizing, fractionCompleted: 0))
        let result = try await runSpeakerKitDiarization(
            diarizer: diarizer,
            audioURL: audioURL,
            duration: duration,
            progress: progress
        )
        try Task.checkCancellation()
        progress(.init(stage: .diarizing, fractionCompleted: 1))

        let intervals = result.segments.compactMap { segment -> DiarizationInterval? in
            guard let speakerIndex = segment.speaker.speakerId else { return nil }
            return DiarizationInterval(
                speakerIndex: speakerIndex,
                startTime: TimeInterval(segment.startTime),
                endTime: TimeInterval(segment.endTime)
            )
        }

        let aligned = try TranscriptSpeakerAligner.applying(
            intervals: intervals,
            to: transcript,
            metadata: DiarizationMetadata(
                engine: "SpeakerKit",
                engineVersion: Self.engineVersion,
                modelID: Self.modelID
            )
        )

        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - overallStart)
        let realTimeFactor = duration > 0 ? elapsed / duration : 0
        Self.logger.info(
            "Speaker identification finished audioSeconds=\(duration) elapsedSeconds=\(elapsed) rtf=\(realTimeFactor) speakers=\(aligned.speakers.count)"
        )
        return aligned
    }

    private func makeEngine(allowsDownload: Bool) -> any SpeakerDiarizationEngine {
        operations.makeEngine(modelRoot, allowsDownload)
    }

    private func ensureModelDirectory() throws {
        try FileManager.default.createDirectory(
            at: modelRoot,
            withIntermediateDirectories: true
        )
    }

    private func hasCompleteModelCache() -> Bool {
        guard modelRoot.resolvingSymlinksInPath() == modelRoot,
              let values = try? modelRoot.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(
                  at: modelRoot,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return false
        }

        var found = Set<String>()
        for case let url as URL in enumerator {
            guard url.resolvingSymlinksInPath() == url,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isDirectory == true else {
                continue
            }

            let baseName = url.deletingPathExtension().lastPathComponent
            if Self.requiredModelNames.contains(baseName) {
                found.insert(baseName)
            }
        }
        return found == Self.requiredModelNames
    }

    private func loadExistingModels(
        progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void
    ) async throws {
        let diarizer = makeEngine(allowsDownload: false)
        modelState = .preparing(0)
        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await diarizer.loadModels()
        try Task.checkCancellation()
        guard diarizer.isLoaded else {
            throw RecordingDiarizationError.speakerModelsNotLoaded
        }
        loadedDiarizer = diarizer
        modelState = .installed
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - loadStart)
        Self.logger.info("Speaker Core ML load finished elapsedSeconds=\(elapsed)")
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
    }

    private func downloadAndLoadModels(
        progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void,
        allowsDownload: Bool
    ) async throws {
        let diarizer = makeEngine(allowsDownload: allowsDownload)
        progress(.init(stage: .downloading, fractionCompleted: 0))
        modelState = .downloading(0)
        try await diarizer.downloadModels { downloadProgress in
            let fraction = Self.clamped(downloadProgress.fractionCompleted)
            progress(.init(stage: .downloading, fractionCompleted: fraction))
        }
        try Task.checkCancellation()
        progress(.init(stage: .downloading, fractionCompleted: 1))

        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        modelState = .preparing(0)
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await diarizer.loadModels()
        try Task.checkCancellation()
        guard diarizer.isLoaded else {
            throw RecordingDiarizationError.speakerModelsNotLoaded
        }
        loadedDiarizer = diarizer
        modelState = .installed
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - loadStart)
        Self.logger.info("Speaker Core ML load finished elapsedSeconds=\(elapsed)")
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
    }

    private func runSpeakerKitDiarization(
        diarizer: any SpeakerDiarizationEngine,
        audioURL: URL,
        duration: TimeInterval,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> DiarizationResult {
        let samples = try BoundedWhisperAudioLoader.loadSamples(
            from: audioURL,
            startTime: 0,
            endTime: duration
        )
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw RecordingDiarizationError.noSpeakerActivity
        }

        let options = PyannoteDiarizationOptions(useExclusiveReconciliation: true)
        return try await diarizer.diarize(
            audioArray: samples,
            options: options,
            progressCallback: { speakerProgress in
                progress(
                    .init(
                        stage: .diarizing,
                        fractionCompleted: Self.clamped(speakerProgress.fractionCompleted)
                    )
                )
            }
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
            throw RecordingDiarizationError.combinedAudioUnavailable(recording.id)
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
            throw RecordingDiarizationError.combinedAudioUnavailable(recording.id)
        }
        throw RecordingDiarizationError.noManagedAudio(recording.id)
    }

    nonisolated private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    nonisolated private static func errorKind(_ error: Error) -> ModelErrorKind {
        if error is URLError || (error as NSError).domain == NSURLErrorDomain {
            return .network
        }
        return .load
    }
}

struct SpeakerDiarizationOperations: Sendable {
    let makeEngine: @Sendable (URL, Bool) -> any SpeakerDiarizationEngine

    init(
        makeEngine: @escaping @Sendable (URL, Bool) -> any SpeakerDiarizationEngine
    ) {
        self.makeEngine = makeEngine
    }

    static let live = SpeakerDiarizationOperations { modelRoot, allowsDownload in
        let config: PyannoteConfig
        if allowsDownload {
            config = PyannoteConfig(
                downloadBase: modelRoot.path,
                download: true,
                load: false,
                verbose: false
            )
        } else {
            config = PyannoteConfig(
                // Keep validation pointed at the same private Hub root used by
                // downloads, but disable network resolution. This loads the
                // repository snapshot under Bardo/Models/SpeakerKit only.
                downloadBase: modelRoot.path,
                download: false,
                load: false,
                verbose: false
            )
        }
        return SpeakerKitDiarizationEngineAdapter(
            base: SpeakerKitDiarizer.pyannote(config: config)
        )
    }
}
