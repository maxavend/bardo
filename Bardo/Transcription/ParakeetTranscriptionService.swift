import Foundation
import OSLog
@preconcurrency import FluidAudio

actor ParakeetTranscriptionService: RecordingTranscribing {
    static let engineVersion = "0.15.6"
    static let modelID = "parakeet-tdt-0.6b-v3-coreml"
    static let defaultIdleUnloadNanoseconds: UInt64 = 20 * 60 * 1_000_000_000

    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "transcription.parakeet"
    )

    private let idleUnloadNanoseconds: UInt64
    private let metadataReader = AudioMetadataReader()

    private var manager: AsrManager?
    private var idleUnloadTask: Task<Void, Never>?

    init(
        idleUnloadNanoseconds: UInt64 = ParakeetTranscriptionService.defaultIdleUnloadNanoseconds
    ) {
        self.idleUnloadNanoseconds = idleUnloadNanoseconds
    }

    nonisolated static var modelDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    nonisolated static func hasInstalledModelOnDisk() -> Bool {
        AsrModels.modelsExist(
            at: modelDirectory,
            version: .v3,
            encoderPrecision: .int8
        )
    }

    func hasInstalledModel() -> Bool {
        Self.hasInstalledModelOnDisk()
    }

    func prepareForUse(
        progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void
    ) async throws {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        progress(.init(stage: .checking, fractionCompleted: 0))

        let models: AsrModels
        if Self.hasInstalledModelOnDisk() {
            progress(.init(stage: .preparingLanguageSupport, fractionCompleted: 1))
            models = try await AsrModels.load(
                from: Self.modelDirectory,
                version: .v3,
                encoderPrecision: .int8
            )
        } else {
            models = try await AsrModels.downloadAndLoad(
                to: Self.modelDirectory,
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { snapshot in
                    progress(
                        .init(
                            stage: .downloading,
                            fractionCompleted: Self.clamped(snapshot.fractionCompleted)
                        )
                    )
                }
            )
        }

        progress(.init(stage: .optimizingForMac, fractionCompleted: 0))
        try await installManager(models)
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
        scheduleIdleUnload()
    }

    func warmUpIfInstalled() async {
        if manager != nil {
            scheduleIdleUnload()
            return
        }
        guard Self.hasInstalledModelOnDisk() else { return }

        do {
            let models = try await AsrModels.load(
                from: Self.modelDirectory,
                version: .v3,
                encoderPrecision: .int8
            )
            try await installManager(models)
            scheduleIdleUnload()
        } catch {
            Self.logger.debug(
                "Background Parakeet warm-up skipped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        let overallStart = ProcessInfo.processInfo.systemUptime
        let (audioURL, duration) = try await resolveAudio(recording: recording, store: store)
        try Task.checkCancellation()

        progress(.init(stage: .preparingModel, fractionCompleted: 0))
        let activeManager = try await ensureManager { fraction in
            progress(.init(stage: .preparingModel, fractionCompleted: fraction))
        }
        try Task.checkCancellation()

        progress(.init(stage: .loadingModel, fractionCompleted: 1))
        progress(.init(stage: .transcribing, fractionCompleted: 0))

        var decoderState = try TdtDecoderState(
            decoderLayers: await activeManager.decoderLayerCount
        )
        let result = try await activeManager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: preferredLanguageHint
        )
        try Task.checkCancellation()

        let segments = ParakeetTranscriptBuilder.segments(
            tokenTimings: result.tokenTimings ?? [],
            fallbackText: result.text,
            duration: duration
        )
        guard !segments.isEmpty else {
            throw RecordingTranscriptionError.decoderReturnedNoResult
        }

        progress(.init(stage: .transcribing, fractionCompleted: 1))
        scheduleIdleUnload()

        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - overallStart)
        let realTimeFactor = duration > 0 ? elapsed / duration : 0
        Self.logger.info(
            "Parakeet finished audioSeconds=\(duration) elapsedSeconds=\(elapsed) rtf=\(realTimeFactor) segments=\(segments.count)"
        )

        return Transcript(
            recordingID: recording.id,
            languageCode: TranscriptionLanguagePreference.current.whisperLanguageCode,
            segments: segments,
            metadata: TranscriptMetadata(
                engine: "FluidAudio",
                engineVersion: Self.engineVersion,
                modelID: Self.modelID,
                coverage: TranscriptionCoverage(
                    completion: .complete,
                    sourceDuration: duration,
                    processedDuration: duration,
                    expectedSampleCount: TranscriptionInputIntegrity.expectedSamples(
                        duration: duration
                    ),
                    processedSampleCount: TranscriptionInputIntegrity.expectedSamples(
                        duration: duration
                    )
                )
            )
        )
    }

    func unload() async {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard let manager else { return }
        self.manager = nil
        await manager.cleanup()
    }

    private func ensureManager(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AsrManager {
        if let manager {
            progress(1)
            return manager
        }

        let models: AsrModels
        if Self.hasInstalledModelOnDisk() {
            progress(0.1)
            models = try await AsrModels.load(
                from: Self.modelDirectory,
                version: .v3,
                encoderPrecision: .int8
            )
        } else {
            models = try await AsrModels.downloadAndLoad(
                to: Self.modelDirectory,
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { snapshot in
                    progress(Self.clamped(snapshot.fractionCompleted * 0.9))
                }
            )
        }
        progress(0.92)
        try await installManager(models)
        progress(1)

        guard let manager else {
            throw RecordingTranscriptionError.decoderReturnedNoResult
        }
        return manager
    }

    private func installManager(_ models: AsrModels) async throws {
        if let manager {
            await manager.cleanup()
        }

        // FluidAudio documents this setting for Parakeet v3 multilingual long-form
        // audio so chunk boundaries do not introduce an English-language prior.
        let manager = AsrManager(config: ASRConfig(melChunkContext: false))
        try await manager.loadModels(models)
        self.manager = manager
    }

    private var preferredLanguageHint: Language? {
        switch TranscriptionLanguagePreference.current {
        case .automatic:
            nil
        case .spanish:
            .spanish
        case .english:
            .english
        }
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
            await self?.unload()
        }
    }

    nonisolated private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

enum ParakeetTranscriptBuilder {
    private static let maximumSegmentDuration: TimeInterval = 12
    private static let pauseBoundary: TimeInterval = 1.25

    static func segments(
        tokenTimings: [TokenTiming],
        fallbackText: String,
        duration: TimeInterval
    ) -> [TranscriptSegment] {
        let wordTimings = buildWordTimings(from: tokenTimings)
        if wordTimings.isEmpty {
            let text = TranscriptTextSanitizer.sanitize(fallbackText)
            guard !text.isEmpty else { return [] }
            return [
                TranscriptSegment(
                    startTime: 0,
                    endTime: max(0, duration),
                    text: text
                )
            ]
        }

        let cues = wordTimings.compactMap { timing -> TranscriptWord? in
            let text = TranscriptTextSanitizer.sanitize(timing.word)
            guard !text.isEmpty else { return nil }
            return TranscriptWord(
                startTime: max(0, timing.startTime),
                endTime: max(timing.startTime, timing.endTime),
                text: text
            )
        }
        guard !cues.isEmpty else { return [] }

        var result: [TranscriptSegment] = []
        var group: [TranscriptWord] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let text = joinedText(group.map(\.text))
            if !text.isEmpty {
                result.append(
                    TranscriptSegment(
                        startTime: first.startTime,
                        endTime: last.endTime,
                        text: text,
                        words: group
                    )
                )
            }
            group.removeAll(keepingCapacity: true)
        }

        for word in cues {
            if let previous = group.last {
                let gap = max(0, word.startTime - previous.endTime)
                let groupDuration = max(
                    0,
                    previous.endTime - (group.first?.startTime ?? previous.startTime)
                )
                let sentenceBoundary = endsSentence(previous.text) && groupDuration >= 3
                if gap >= pauseBoundary
                    || groupDuration >= maximumSegmentDuration
                    || sentenceBoundary {
                    flush()
                }
            }
            group.append(word)
        }
        flush()

        return result
    }

    private static func joinedText(_ words: [String]) -> String {
        var text = ""
        for word in words {
            guard !word.isEmpty else { continue }
            if text.isEmpty {
                text = word
                continue
            }

            if attachesToPrevious(word) || text.last.map(isOpeningPunctuation) == true {
                text += word
            } else {
                text += " " + word
            }
        }
        return TranscriptTextSanitizer.sanitize(text)
    }

    private static func attachesToPrevious(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return ".,!?;:%)]}…'’".contains(first)
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{¿¡".contains(character)
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?…".contains(last)
    }
}
