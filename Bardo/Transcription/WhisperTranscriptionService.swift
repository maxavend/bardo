import Foundation
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

protocol RecordingTranscribing: Sendable {
    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript
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

actor WhisperTranscriptionService: RecordingTranscribing {
    static let engineVersion = "1.0.0"

    private let modelManager: TranscriptionModelManager
    private let chunkDuration: TimeInterval
    private let overlap: TimeInterval

    init(
        modelManager: TranscriptionModelManager,
        chunkDuration: TimeInterval = TranscriptionChunkPlanner.defaultChunkDuration,
        overlap: TimeInterval = TranscriptionChunkPlanner.defaultOverlap
    ) {
        self.modelManager = modelManager
        self.chunkDuration = chunkDuration
        self.overlap = overlap
    }

    static func live() throws -> WhisperTranscriptionService {
        WhisperTranscriptionService(modelManager: try TranscriptionModelManager.live())
    }

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        let cancellation = TranscriptionCancellationFlag()
        return try await withTaskCancellationHandler {
            try await transcribeInternal(
                recording: recording,
                store: store,
                cancellation: cancellation,
                progress: progress
            )
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

        let (audioURL, duration) = try await resolveAudio(recording: recording, store: store)
        let plans = TranscriptionChunkPlanner.plans(
            duration: duration,
            chunkDuration: chunkDuration,
            overlap: overlap
        )
        guard !plans.isEmpty else { throw RecordingTranscriptionError.invalidDuration }

        progress(.init(stage: .preparingModel, fractionCompleted: 0))
        let modelFolder = try await modelManager.ensureModelAvailable { fraction in
            progress(.init(stage: .preparingModel, fractionCompleted: fraction))
        }
        try checkCancellation(cancellation)

        progress(.init(stage: .loadingModel, fractionCompleted: 0))
        let config = WhisperKitConfig(
            model: nil,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)
        progress(.init(stage: .loadingModel, fractionCompleted: 1))

        do {
            let transcript = try await transcribeChunks(
                recordingID: recording.id,
                audioURL: audioURL,
                plans: plans,
                whisper: whisper,
                modelID: await modelManager.selectedModelID(),
                cancellation: cancellation,
                progress: progress
            )
            await whisper.unloadModels()
            return transcript
        } catch {
            await whisper.unloadModels()
            throw error
        }
    }

    private func transcribeChunks(
        recordingID: Recording.ID,
        audioURL: URL,
        plans: [TranscriptionChunkPlan],
        whisper: WhisperKit,
        modelID: String,
        cancellation: TranscriptionCancellationFlag,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        var segments: [TranscriptSegment] = []
        var detectedLanguage: String?

        for (index, plan) in plans.enumerated() {
            try checkCancellation(cancellation)

            let samples = try BoundedWhisperAudioLoader.loadSamples(
                from: audioURL,
                startTime: plan.startTime,
                endTime: plan.endTime
            )
            guard !samples.isEmpty else { continue }

            let options = DecodingOptions(
                usePrefillPrompt: false,
                wordTimestamps: true,
                chunkingStrategy: .vad
            )
            let results = try await whisper.transcribe(
                audioArray: samples,
                decodeOptions: options,
                callback: { _ in
                    cancellation.isCancelled ? false : true
                }
            )
            try checkCancellation(cancellation)

            for result in results {
                if detectedLanguage == nil, !result.language.isEmpty {
                    detectedLanguage = result.language
                }
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
            }

            progress(.init(
                stage: .transcribing,
                fractionCompleted: Double(index + 1) / Double(plans.count)
            ))
        }

        segments.sort {
            if $0.startTime == $1.startTime { return $0.id.uuidString < $1.id.uuidString }
            return $0.startTime < $1.startTime
        }
        guard !segments.isEmpty else { throw RecordingTranscriptionError.emptyTranscription }

        return Transcript(
            recordingID: recordingID,
            languageCode: detectedLanguage,
            segments: segments,
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: Self.engineVersion,
                modelID: modelID
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

    private func checkCancellation(_ cancellation: TranscriptionCancellationFlag) throws {
        if cancellation.isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }
}
