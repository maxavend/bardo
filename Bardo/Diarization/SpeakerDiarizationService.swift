import Foundation
import OSLog
@preconcurrency import ArgmaxCore
@preconcurrency import SpeakerKit

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
    case checking
    case downloading
    case optimizingForMac
}

struct DiarizationSetupProgressSnapshot: Equatable, Sendable {
    let stage: DiarizationSetupStage
    let fractionCompleted: Double
}

protocol SpeakerDiarizationEngine: AnyObject, Sendable {
    var isLoaded: Bool { get }
    func downloadModels(progressCallback: (@Sendable (Progress) -> Void)?) async throws
    func loadModels() async throws
    func diarize(
        audioArray: [Float],
        options: (any DiarizationOptions)?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DiarizationResult
}

final class SpeakerKitDiarizationEngineAdapter: SpeakerDiarizationEngine {
    private let base: SpeakerKitDiarizer

    init(base: SpeakerKitDiarizer) { self.base = base }
    var isLoaded: Bool { base.isLoaded }

    func downloadModels(progressCallback: (@Sendable (Progress) -> Void)?) async throws {
        let manager: ModelManager = base
        try await manager.downloadModels(progressCallback: progressCallback)
    }

    func loadModels() async throws { try await base.loadModels() }

    func diarize(
        audioArray: [Float],
        options: (any DiarizationOptions)?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DiarizationResult {
        try await base.diarize(audioArray: audioArray, options: options, progressCallback: progressCallback)
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
    case speakerModelsUnavailable
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
        case .speakerModelsUnavailable:
            return "Bardo could not download or verify the private SpeakerKit models. Check the connection and try again."
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

/// Applies speaker intervals to words and reconstructs natural conversation turns.
/// Existing text edits and old transcripts without word timestamps remain intact.
enum TranscriptSpeakerAligner {
    static func applying(
        intervals: [DiarizationInterval],
        to transcript: Transcript,
        metadata: DiarizationMetadata
    ) throws -> Transcript {
        let validIntervals = intervals
            .filter {
                $0.speakerIndex >= 0 && $0.startTime.isFinite
                    && $0.endTime.isFinite && $0.endTime > $0.startTime
            }
            .sorted {
                if $0.startTime == $1.startTime {
                    if $0.endTime == $1.endTime { return $0.speakerIndex < $1.speakerIndex }
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }
        guard !validIntervals.isEmpty else { throw RecordingDiarizationError.noSpeakerActivity }

        let order = orderedSpeakerIndices(from: validIntervals)
        let speakers = speakersForDiarization(order: order, transcript: transcript)
        let speakerIDs = Dictionary(uniqueKeysWithValues: zip(order, speakers.map(\.id)))

        var updated = transcript
        updated.speakers = speakers
        updated.diarizationMetadata = metadata

        if transcript.hasManualTextEdits || transcript.segments.allSatisfy({ $0.words.isEmpty }) {
            for index in updated.segments.indices {
                updated.segments[index].speakerID = bestSpeakerID(
                    for: updated.segments[index], intervals: validIntervals, speakerIDs: speakerIDs
                )
            }
            return updated
        }

        let words = transcript.segments.flatMap(\.words).sorted {
            $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
        }
        let attributedWords = BardoWordSpeakerAligner.attributed(
            words: words, intervals: validIntervals, speakerIDs: speakerIDs
        )
        let rebuilt = BardoConversationTurnBuilder.build(from: attributedWords)
        if !rebuilt.isEmpty { updated.segments = rebuilt }
        return updated
    }

    private static func orderedSpeakerIndices(from intervals: [DiarizationInterval]) -> [Int] {
        var seen = Set<Int>()
        return intervals.compactMap { seen.insert($0.speakerIndex).inserted ? $0.speakerIndex : nil }
    }

    private static func speakersForDiarization(order: [Int], transcript: Transcript) -> [Speaker] {
        var existingIDs: [Speaker.ID] = []
        var seen = Set<Speaker.ID>()
        for segment in transcript.segments {
            if let id = segment.speakerID, seen.insert(id).inserted { existingIDs.append(id) }
        }
        for speaker in transcript.speakers where seen.insert(speaker.id).inserted { existingIDs.append(speaker.id) }

        return order.indices.map { index in
            if index < existingIDs.count,
               let existing = transcript.speakers.first(where: { $0.id == existingIDs[index] }) {
                return existing
            }
            return Speaker()
        }
    }

    private static func bestSpeakerID(
        for segment: TranscriptSegment,
        intervals: [DiarizationInterval],
        speakerIDs: [Int: Speaker.ID]
    ) -> Speaker.ID? {
        let words = segment.words.isEmpty
            ? [TranscriptWord(startTime: segment.startTime, endTime: segment.endTime, text: segment.text)]
            : segment.words
        var scores: [Int: Int] = [:]
        for word in BardoWordSpeakerAligner.align(words: words, intervals: intervals) {
            if let index = word.speakerIndex { scores[index, default: 0] += 1 }
        }
        return scores.max {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }.flatMap { speakerIDs[$0.key] }
    }
}

struct DiarizationPerformanceMetrics: Equatable, Sendable {
    let audioSeconds: TimeInterval
    let elapsedSeconds: TimeInterval
    let realTimeFactor: Double
    let alignmentAndTurnBuildMilliseconds: Double
    let speakerCount: Int
    let segmentCount: Int
    let wordCount: Int
}

actor SpeakerDiarizationService: RecordingDiarizing {
    static let engineVersion = "1.1.0"
    static let modelID = "pyannote-v3+plda-v4"
    private static let logger = Logger(subsystem: "com.maxavend.bardo", category: "diarization.performance")
    private static let sharedServiceResult: Result<SpeakerDiarizationService, Error> = Result {
        SpeakerDiarizationService(modelStore: try BardoModelStore.live(), operations: .live)
    }

    private let modelStore: BardoModelStore
    private let modelRoot: URL
    private let operations: SpeakerDiarizationOperations
    private var loadedDiarizer: (any SpeakerDiarizationEngine)?
    private var modelState: ManagedModelState = .notInstalled
    private(set) var lastMetrics: DiarizationPerformanceMetrics?

    init(modelStore: BardoModelStore, operations: SpeakerDiarizationOperations = .live) {
        self.modelStore = modelStore
        modelRoot = modelStore.root(for: .speakerKit).standardizedFileURL
        self.operations = operations
    }

    static func live() throws -> SpeakerDiarizationService { try sharedServiceResult.get() }

    func hasInstalledModels() async -> Bool {
        if let loadedDiarizer, loadedDiarizer.isLoaded {
            modelState = .installed
            return true
        }
        guard hasCompleteModelCache() else { modelState = .notInstalled; return false }
        do { try await loadIfNeeded(); return true }
        catch {
            loadedDiarizer = nil
            modelState = .failed(error.localizedDescription)
            return false
        }
    }

    func warmUpIfInstalled() async {
        guard hasCompleteModelCache() else { return }
        do { try await loadIfNeeded() }
        catch { Self.logger.debug("Background speaker warm-up skipped: \(error.localizedDescription, privacy: .public)") }
    }

    func prepareForUse(
        progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void
    ) async throws {
        try Task.checkCancellation()
        try ensureModelDirectory()
        progress(.init(stage: .checking, fractionCompleted: 0))
        progress(.init(stage: .checking, fractionCompleted: 1))
        if let loadedDiarizer, loadedDiarizer.isLoaded {
            modelState = .installed
            progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
            return
        }

        if hasCompleteModelCache() {
            do {
                try await loadIfNeeded(progress: progress)
                return
            } catch {
                loadedDiarizer = nil
                try modelStore.reset(.speakerKit)
                try ensureModelDirectory()
            }
        }
        try await downloadAndLoadModels(progress: progress)
    }

    func state() -> ManagedModelState { modelState }

    func reset() throws {
        loadedDiarizer = nil
        try modelStore.reset(.speakerKit)
        modelState = .notInstalled
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
        guard duration.isFinite, duration > 0 else { throw RecordingDiarizationError.invalidDuration }

        try await prepareForUse { snapshot in
            let stage: DiarizationStage = snapshot.stage == .downloading
                ? .preparingModel
                : .loadingModel
            progress(.init(stage: stage, fractionCompleted: snapshot.fractionCompleted))
        }
        guard let diarizer = loadedDiarizer, diarizer.isLoaded else {
            throw RecordingDiarizationError.speakerModelsNotLoaded
        }

        progress(.init(stage: .diarizing, fractionCompleted: 0))
        let result = try await runSpeakerKitDiarization(
            diarizer: diarizer, audioURL: audioURL, duration: duration, progress: progress
        )
        try Task.checkCancellation()
        progress(.init(stage: .diarizing, fractionCompleted: 1))

        let intervals = result.segments.compactMap { segment -> DiarizationInterval? in
            guard let index = segment.speaker.speakerId else { return nil }
            return DiarizationInterval(speakerIndex: index, startTime: TimeInterval(segment.startTime), endTime: TimeInterval(segment.endTime))
        }
        let alignmentStart = ProcessInfo.processInfo.systemUptime
        let aligned = try TranscriptSpeakerAligner.applying(
            intervals: intervals, to: transcript,
            metadata: DiarizationMetadata(engine: "SpeakerKit", engineVersion: Self.engineVersion, modelID: Self.modelID)
        )
        let alignmentMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - alignmentStart) * 1_000
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - overallStart)
        var finalized = aligned
        finalized.diarizationMetadata = DiarizationMetadata(
            engine: "SpeakerKit",
            engineVersion: Self.engineVersion,
            modelID: Self.modelID,
            processingDuration: elapsed
        )
        lastMetrics = DiarizationPerformanceMetrics(
            audioSeconds: duration, elapsedSeconds: elapsed, realTimeFactor: elapsed / duration,
            alignmentAndTurnBuildMilliseconds: alignmentMilliseconds,
            speakerCount: finalized.speakers.count, segmentCount: finalized.segments.count,
            wordCount: finalized.segments.reduce(0) { $0 + $1.words.count }
        )
        Self.logger.info("Speaker identification finished audioSeconds=\(duration) elapsedSeconds=\(elapsed) rtf=\(elapsed / duration) speakers=\(finalized.speakers.count) segments=\(finalized.segments.count) words=\(finalized.segments.reduce(0) { $0 + $1.words.count })")
        return finalized
    }

    private func loadIfNeeded(
        progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void = { _ in }
    ) async throws {
        if let loadedDiarizer, loadedDiarizer.isLoaded {
            modelState = .installed
            progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
            return
        }
        try Task.checkCancellation()
        guard hasCompleteModelCache() else { throw RecordingDiarizationError.speakerModelsUnavailable }

        let diarizer = operations.makeEngine(modelRoot, false)
        modelState = .preparing(0)
        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await diarizer.loadModels()
        try Task.checkCancellation()
        guard diarizer.isLoaded else { throw RecordingDiarizationError.speakerModelsNotLoaded }
        loadedDiarizer = diarizer
        modelState = .installed
        Self.logger.info("Speaker Core ML load finished elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - loadStart)")
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
    }

    private func ensureModelDirectory() throws {
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
    }

    private func hasCompleteModelCache() -> Bool {
        guard modelRoot.resolvingSymlinksInPath() == modelRoot,
              let values = try? modelRoot.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(
                  at: modelRoot,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return false }

        var found = Set<String>()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isDirectory == true else { continue }
            let baseName = url.deletingPathExtension().lastPathComponent
            if Self.requiredModelNames.contains(baseName) {
                found.insert(baseName)
            }
            if Self.requiredModelNames.contains(baseName),
               let nested = FileManager.default.enumerator(
                   at: url,
                   includingPropertiesForKeys: nil,
                   options: [.skipsHiddenFiles]
               ) {
                for case let child as URL in nested {
                    let childBaseName = child.deletingPathExtension().lastPathComponent
                    if Self.requiredModelNames.contains(childBaseName) {
                        found.insert(childBaseName)
                    }
                }
            }
        }
        return found == Self.requiredModelNames
    }

    private static let requiredModelNames: Set<String> = [
        "SpeakerSegmenter", "SpeakerEmbedderPreprocessor", "SpeakerEmbedder", "PldaProjector"
    ]

    private func downloadAndLoadModels(
        progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void
    ) async throws {
        let diarizer = operations.makeEngine(modelRoot, true)
        progress(.init(stage: .downloading, fractionCompleted: 0))
        modelState = .downloading(0)
        try await diarizer.downloadModels { downloadProgress in
            let fraction = Self.clamped(downloadProgress.fractionCompleted)
            progress(.init(stage: .downloading, fractionCompleted: fraction))
        }
        try Task.checkCancellation()
        progress(.init(stage: .downloading, fractionCompleted: 1))
        try await load(diarizer, progress: progress)
    }

    private func load(
        _ diarizer: any SpeakerDiarizationEngine,
        progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void
    ) async throws {
        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        modelState = .preparing(0)
        try await diarizer.loadModels()
        try Task.checkCancellation()
        guard diarizer.isLoaded else { throw RecordingDiarizationError.speakerModelsNotLoaded }
        loadedDiarizer = diarizer
        modelState = .installed
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
    }

    private func runSpeakerKitDiarization(
        diarizer: any SpeakerDiarizationEngine,
        audioURL: URL,
        duration: TimeInterval,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> DiarizationResult {
        // Full-file inference keeps speaker embeddings globally consistent. The bounded
        // loader limits peak audio memory without splitting the diarization identity space.
        let samples = try BoundedWhisperAudioLoader.loadSamples(from: audioURL, startTime: 0, endTime: duration)
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw RecordingDiarizationError.noSpeakerActivity }
        let options = PyannoteDiarizationOptions(useExclusiveReconciliation: true, centroidSource: .finalAssignment)
        return try await diarizer.diarize(audioArray: samples, options: options) { speakerProgress in
            progress(.init(stage: .diarizing, fractionCompleted: Self.clamped(speakerProgress.fractionCompleted)))
        }
    }

    private func resolveAudio(recording: Recording, store: RecordingStore) async throws -> (URL, TimeInterval) {
        let candidates = TranscriptionAudioSelection.candidates(for: recording)
        let isDualCapture = recording.sources.contains(.systemAudio) && recording.sources.contains(.microphone)
        guard !isDualCapture || !candidates.isEmpty else { throw RecordingDiarizationError.combinedAudioUnavailable(recording.id) }
        for asset in candidates {
            do {
                let url = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
                if asset.metadata.duration.isFinite, asset.metadata.duration > 0 { return (url, asset.metadata.duration) }
            } catch { continue }
        }
        if isDualCapture { throw RecordingDiarizationError.combinedAudioUnavailable(recording.id) }
        throw RecordingDiarizationError.noManagedAudio(recording.id)
    }

    nonisolated private static func clamped(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }
}

struct SpeakerDiarizationOperations: Sendable {
    let makeEngine: @Sendable (URL, Bool) -> any SpeakerDiarizationEngine

    init(makeEngine: @escaping @Sendable (URL, Bool) -> any SpeakerDiarizationEngine) { self.makeEngine = makeEngine }

    static let live = SpeakerDiarizationOperations { modelRoot, allowsDownload in
        let config = PyannoteConfig(
            downloadBase: modelRoot.path, download: allowsDownload, load: false, verbose: false,
            fullRedundancy: true, concurrentSegmenterWorkers: 4, concurrentEmbedderWorkers: nil
        )
        return SpeakerKitDiarizationEngineAdapter(base: SpeakerKitDiarizer.pyannote(config: config))
    }
}
