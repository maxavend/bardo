import Foundation
import OSLog
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
    case downloading
    case optimizingForMac
}

struct DiarizationSetupProgressSnapshot: Equatable, Sendable {
    let stage: DiarizationSetupStage
    let fractionCompleted: Double
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
    case speakerKitReturnedNoSegments
    case speakerKitReturnedNoUsableSpeakers
    case alignmentProducedNoAssignments

    var errorDescription: String? {
        switch self {
        case .noManagedAudio:
            return BardoL10n.current("Bardo could not read this recording’s managed audio for speaker identification.")
        case .combinedAudioUnavailable:
            return BardoL10n.current("The combined System Audio + Microphone track is unavailable. Bardo preserved the original tracks.")
        case .invalidDuration:
            return BardoL10n.current("Bardo could not determine a valid audio duration for speaker identification.")
        case .noSpeakerActivity:
            return BardoL10n.current("Bardo could not find clear speaker activity in this recording. The transcript is unchanged.")
        case .speakerKitReturnedNoSegments:
            return BardoL10n.current("Bardo could not find clear speaker turns in this recording. The transcript is unchanged.")
        case .speakerKitReturnedNoUsableSpeakers:
            return BardoL10n.current("Speaker detection finished, but the result did not contain usable speaker labels. The transcript is unchanged.")
        case .alignmentProducedNoAssignments:
            return BardoL10n.current("Bardo detected voices, but could not align them reliably with the transcript. The transcript is unchanged.")
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

        if !updated.segments.isEmpty,
           updated.segments.allSatisfy({ $0.speakerID == nil }) {
            throw RecordingDiarizationError.alignmentProducedNoAssignments
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
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent("Bardo", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("SpeakerKit", isDirectory: true)
        return SpeakerDiarizationService(modelRoot: root)
    }

    private let modelRoot: URL
    private var loadedDiarizer: SpeakerKitDiarizer?

    init(modelRoot: URL) {
        self.modelRoot = modelRoot
    }

    static func live() throws -> SpeakerDiarizationService {
        try sharedServiceResult.get()
    }

    func hasInstalledModels() -> Bool {
        guard FileManager.default.fileExists(atPath: modelRoot.path),
              let enumerator = FileManager.default.enumerator(
                at: modelRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return false
        }

        var found = Set<String>()
        for case let url as URL in enumerator {
            let baseName = url.deletingPathExtension().lastPathComponent
            if Self.requiredModelNames.contains(baseName) {
                found.insert(baseName)
                if found == Self.requiredModelNames { return true }
            }
        }
        return false
    }

    func warmUpIfInstalled() async {
        guard hasInstalledModels() else { return }
        do {
            try await prepareForUse { _ in }
        } catch {
            Self.logger.debug("Background speaker warm-up skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prepareForUse(
        progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void
    ) async throws {
        try ensureModelDirectory()
        let diarizer = engine()

        if diarizer.isLoaded {
            progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
            return
        }

        progress(.init(stage: .downloading, fractionCompleted: 0))
        let downloadProgressHandler: @Sendable (Progress) -> Void = { downloadProgress in
            progress(
                .init(
                    stage: .downloading,
                    fractionCompleted: Self.clamped(downloadProgress.fractionCompleted)
                )
            )
        }
        let downloadModels: ((@Sendable (Progress) -> Void)?) async throws -> Void =
            diarizer.downloadModels(progressCallback:)
        try await downloadModels(downloadProgressHandler)
        progress(.init(stage: .downloading, fractionCompleted: 1))

        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await diarizer.loadModels()
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - loadStart)
        Self.logger.info("Speaker Core ML load finished elapsedSeconds=\(elapsed)")
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
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

        try ensureModelDirectory()
        let diarizer = engine()

        progress(.init(stage: .preparingModel, fractionCompleted: 0))
        let downloadProgressHandler: @Sendable (Progress) -> Void = { downloadProgress in
            progress(
                .init(
                    stage: .preparingModel,
                    fractionCompleted: Self.clamped(downloadProgress.fractionCompleted)
                )
            )
        }
        let downloadModels: ((@Sendable (Progress) -> Void)?) async throws -> Void =
            diarizer.downloadModels(progressCallback:)
        try await downloadModels(downloadProgressHandler)
        try Task.checkCancellation()
        progress(.init(stage: .preparingModel, fractionCompleted: 1))

        progress(.init(stage: .loadingModel, fractionCompleted: 0))
        try await diarizer.loadModels()
        try Task.checkCancellation()
        progress(.init(stage: .loadingModel, fractionCompleted: 1))

        progress(.init(stage: .diarizing, fractionCompleted: 0))
        let result = try await runSpeakerKitDiarization(
            diarizer: diarizer,
            audioURL: audioURL,
            duration: duration,
            progress: progress
        )
        try Task.checkCancellation()
        progress(.init(stage: .diarizing, fractionCompleted: 1))

        guard !result.segments.isEmpty else {
            Self.logger.error(
                "Speaker identification failed outcome=no-segments audioSeconds=\(duration) rawSegments=0"
            )
            throw RecordingDiarizationError.speakerKitReturnedNoSegments
        }

        let intervals = result.segments.compactMap { segment -> DiarizationInterval? in
            guard let speakerIndex = segment.speaker.speakerId else { return nil }
            return DiarizationInterval(
                speakerIndex: speakerIndex,
                startTime: TimeInterval(segment.startTime),
                endTime: TimeInterval(segment.endTime)
            )
        }

        guard !intervals.isEmpty else {
            Self.logger.error(
                "Speaker identification failed outcome=no-usable-speakers rawSegments=\(result.segments.count) usableIntervals=0"
            )
            throw RecordingDiarizationError.speakerKitReturnedNoUsableSpeakers
        }

        let uniqueSpeakerCount = Set(intervals.map(\.speakerIndex)).count
        Self.logger.info(
            "SpeakerKit result rawSegments=\(result.segments.count) usableIntervals=\(intervals.count) uniqueSpeakers=\(uniqueSpeakerCount)"
        )

        let aligned: Transcript
        do {
            aligned = try TranscriptSpeakerAligner.applying(
                intervals: intervals,
                to: transcript,
                metadata: DiarizationMetadata(
                    engine: "SpeakerKit",
                    engineVersion: Self.engineVersion,
                    modelID: Self.modelID
                )
            )
        } catch RecordingDiarizationError.alignmentProducedNoAssignments {
            Self.logger.error(
                "Speaker identification failed outcome=alignment-no-assignments rawSegments=\(result.segments.count) usableIntervals=\(intervals.count) transcriptSegments=\(transcript.segments.count)"
            )
            throw RecordingDiarizationError.alignmentProducedNoAssignments
        }

        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - overallStart)
        let realTimeFactor = duration > 0 ? elapsed / duration : 0
        let assignedSegments = aligned.segments.filter { $0.speakerID != nil }.count
        if aligned.speakers.count == 1 {
            Self.logger.warning(
                "Speaker identification finished outcome=single-speaker audioSeconds=\(duration) elapsedSeconds=\(elapsed) rtf=\(realTimeFactor) assignedSegments=\(assignedSegments)"
            )
        } else {
            Self.logger.info(
                "Speaker identification finished outcome=normal audioSeconds=\(duration) elapsedSeconds=\(elapsed) rtf=\(realTimeFactor) speakers=\(aligned.speakers.count) assignedSegments=\(assignedSegments)"
            )
        }
        return aligned
    }

    private func engine() -> SpeakerKitDiarizer {
        if let loadedDiarizer { return loadedDiarizer }

        let config = PyannoteConfig(
            downloadBase: modelRoot.path,
            download: true,
            load: false,
            verbose: false
        )
        let diarizer = SpeakerKitDiarizer.pyannote(config: config)
        loadedDiarizer = diarizer
        return diarizer
    }

    private func ensureModelDirectory() throws {
        try FileManager.default.createDirectory(
            at: modelRoot,
            withIntermediateDirectories: true
        )
    }

    private func runSpeakerKitDiarization(
        diarizer: SpeakerKitDiarizer,
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
}
