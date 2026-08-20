import Foundation
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
    static let engineVersion = "1.0.0"
    static let modelID = "pyannote-v3+plda-v4"

    private let modelRoot: URL

    init(modelRoot: URL) {
        self.modelRoot = modelRoot
    }

    static func live() throws -> SpeakerDiarizationService {
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

    func diarize(
        recording: Recording,
        transcript: Transcript,
        store: RecordingStore,
        progress: @escaping @Sendable (DiarizationProgressSnapshot) -> Void
    ) async throws -> Transcript {
        try Task.checkCancellation()
        let (audioURL, duration) = try await resolveAudio(recording: recording, store: store)
        guard duration.isFinite, duration > 0 else {
            throw RecordingDiarizationError.invalidDuration
        }

        try FileManager.default.createDirectory(
            at: modelRoot,
            withIntermediateDirectories: true
        )

        progress(.init(stage: .preparingModel, fractionCompleted: 0))
        let config = PyannoteConfig(
            downloadBase: modelRoot.path,
            download: false,
            load: false,
            verbose: false
        )
        let speakerKit = try await SpeakerKit(config)
        if let modelManager = speakerKit.diarizer as? SpeakerKitDiarizer {
            try await modelManager.downloadModels { downloadProgress in
                progress(
                    .init(
                        stage: .preparingModel,
                        fractionCompleted: Self.clamped(downloadProgress.fractionCompleted)
                    )
                )
            }
        } else {
            try await speakerKit.diarizer.downloadModels()
        }
        try Task.checkCancellation()
        progress(.init(stage: .preparingModel, fractionCompleted: 1))

        progress(.init(stage: .loadingModel, fractionCompleted: 0))
        try await speakerKit.diarizer.loadModels()
        try Task.checkCancellation()
        progress(.init(stage: .loadingModel, fractionCompleted: 1))

        do {
            progress(.init(stage: .diarizing, fractionCompleted: 0))
            // SpeakerKit 1.0.0's public diarization API accepts one complete 16 kHz mono
            // Float array. Keep that allocation scoped to inference so it can be released
            // before transcript alignment and persistence; do not create another full copy here.
            let result = try await runSpeakerKitDiarization(
                speakerKit: speakerKit,
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
            await speakerKit.unloadModels()
            return aligned
        } catch {
            await speakerKit.unloadModels()
            throw error
        }
    }

    private func runSpeakerKitDiarization(
        speakerKit: SpeakerKit,
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
        return try await speakerKit.diarize(
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
