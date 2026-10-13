import Foundation
import NaturalLanguage
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

    /// Transcribes a recording with a microphone and Mac audio track per track or as
    /// their mix; other recordings ignore `trackMode`.
    func transcribe(
        recording: Recording,
        store: RecordingStore,
        trackMode: TranscriptionTrackMode,
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

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        trackMode: TranscriptionTrackMode,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void,
        liveUpdate: @escaping @Sendable (TranscriptionLiveSnapshot) -> Void
    ) async throws -> Transcript {
        try await transcribe(recording: recording, store: store, progress: progress, liveUpdate: liveUpdate)
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
            return String(localized: "Recording \(id.uuidString) has no readable managed audio to transcribe.")
        case .combinedAudioUnavailable:
            return String(localized: "The combined System Audio + Microphone track is unavailable. Bardo preserved the original tracks; regenerate the conversation mix before transcribing.")
        case .invalidDuration:
            return String(localized: "Bardo could not determine a valid audio duration for transcription.")
        case .emptyTranscription:
            return String(localized: "WhisperKit completed without producing any transcript segments.")
        }
    }
}

enum TranscriptionAudioSelection {
    /// The original tracks to transcribe apart, Mac audio first so the microphone's echo
    /// of it can be recognised; nil when the recording is not a dual capture, the mix
    /// was chosen, or an original is missing.
    static func separateTracks(
        for recording: Recording,
        mode: TranscriptionTrackMode
    ) -> (system: AudioAsset, microphone: AudioAsset)? {
        guard mode == .perTrack,
              recording.sources.contains(.systemAudio),
              recording.sources.contains(.microphone),
              let system = recording.audioAssets.first(where: { $0.role == .systemOriginal }),
              let microphone = recording.audioAssets.first(where: { $0.role == .microphoneOriginal })
        else { return nil }
        return (system, microphone)
    }

    static func candidates(for recording: Recording) -> [AudioAsset] {
        let isDualCapture = recording.sources.contains(.systemAudio)
            && recording.sources.contains(.microphone)
        if isDualCapture {
            return recording.audioAssets.filter { $0.role == .conversationMix }
        }
        return recording.playbackAudioAssets
    }
}

/// One file to listen to and where it sits on the recording's timeline.
struct TranscriptionPass: Sendable {
    let url: URL
    let duration: TimeInterval
    let offset: TimeInterval
    let source: TranscriptSource?
}

struct TranscriptionPlan: Sendable {
    let passes: [TranscriptionPass]
    let timelineDuration: TimeInterval
    let trackMode: TranscriptionTrackMode?

    var isPerTrack: Bool { trackMode == .perTrack }
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
        let source: TranscriptSource?

        init(_ segment: TranscriptSegment) {
            startMilliseconds = Int((segment.startTime * 1_000).rounded())
            endMilliseconds = Int((segment.endTime * 1_000).rounded())
            source = segment.source
        }
    }

    private let lock = NSLock()
    private let recordingID: Recording.ID
    private let audioDuration: TimeInterval
    private let passCount: Int
    private var segmentsByKey: [SegmentKey: TranscriptSegment] = [:]
    private var provisionalText = ""
    private var pass = 0
    private var passProcessedTime: TimeInterval = 0

    /// `passCount` is how many times the timeline is listened to: once for one track,
    /// twice when the microphone and the Mac's audio are transcribed apart.
    init(recordingID: Recording.ID, audioDuration: TimeInterval, passCount: Int = 1) {
        self.recordingID = recordingID
        self.audioDuration = audioDuration
        self.passCount = max(1, passCount)
    }

    /// Starts listening to the timeline again for the next track.
    func beginPass(_ index: Int) -> TranscriptionLiveSnapshot {
        lock.lock()
        defer { lock.unlock() }
        pass = min(max(0, index), passCount - 1)
        passProcessedTime = 0
        return makeSnapshot()
    }

    func updateProvisionalText(_ text: String) -> TranscriptionLiveSnapshot {
        lock.lock()
        defer { lock.unlock() }

        provisionalText = segmentsByKey.isEmpty
            ? TranscriptTextSanitizer.normalizeRecognizedText(text).trimmingCharacters(in: .whitespacesAndNewlines)
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
                editedText: segment.editedText,
                source: segment.source
            )
            passProcessedTime = max(passProcessedTime, segment.endTime)
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
        // Every pass covers the whole timeline, so progress counts finished passes in full.
        let passTime = min(passProcessedTime, audioDuration)
        let processedAudioTime = (Double(pass) * audioDuration + passTime) / Double(passCount)

        return TranscriptionLiveSnapshot(
            recordingID: recordingID,
            segments: sortedSegments,
            provisionalText: provisionalText,
            processedAudioTime: processedAudioTime,
            audioDuration: audioDuration
        )
    }
}

/// Carries a freshly loaded engine back to the transcription actor, which is the only
/// place that uses it afterwards.
final class LoadedWhisperEngine: @unchecked Sendable {
    let whisper: WhisperKit

    init(_ whisper: WhisperKit) {
        self.whisper = whisper
    }
}

struct WhisperTranscriptionMetrics: Equatable, Sendable {
    let audioSeconds: TimeInterval
    let asrSeconds: TimeInterval
    let asrRealTimeFactor: Double
    let segmentCount: Int
    let wordCount: Int
    let incrementalChunkDurationSeconds: Double
    let maxBufferedChunks: Int
    let workerCount: Int
    let fallbackCount: Int
    let vadWindowCount: Int
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
    private let performanceProfile: WhisperPerformanceProfile
    private let idleUnloadNanoseconds: UInt64

    private var loadedWhisper: WhisperKit?
    /// One Core ML load at a time; concurrent callers share it instead of loading the
    /// model twice and doubling peak memory.
    private var engineLoad: Task<LoadedWhisperEngine, Error>?
    /// Operations currently relying on the loaded engine. The idle unload and resets
    /// never run while this is above zero.
    private var activeOperations = 0
    /// WhisperKit keeps per-run callbacks on the shared engine, so transcriptions run
    /// one at a time.
    private var isTranscribing = false
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleUnloadTask: Task<Void, Never>?
    /// Set for the whole reset, so work cannot start while the files are being removed.
    private var isResetting = false
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

    var isInUse: Bool {
        activeOperations > 0 || engineLoad != nil || isTranscribing || isResetting
    }

    func reset() async throws {
        guard !isInUse else { throw ModelOperationError.inUse }
        isResetting = true
        defer { isResetting = false }
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
        guard !isResetting else { throw ModelOperationError.inUse }
        beginOperation()
        defer { endOperation() }
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
            try Task.checkCancellation()
            loadedWhisper = nil
            try await modelManager.reset()
            progress(.init(stage: .downloading, fractionCompleted: 0))
            resources = try await modelManager.ensureResourcesAvailable { fraction in
                progress(.init(stage: .downloading, fractionCompleted: Self.clamped(fraction)))
            }
            _ = try await engine(resources: resources, progress: { _ in })
        }
        progress(.init(stage: .optimizingForMac, fractionCompleted: 1))
    }

    func warmUpIfInstalled() async {
        guard !isResetting else { return }
        beginOperation()
        defer { endOperation() }
        guard loadedWhisper == nil else { return }

        do {
            guard try await modelManager.hasInstalledModel() else { return }
            let resources = try await modelManager.ensureResourcesAvailable()
            _ = try await engine(resources: resources, progress: { _ in })
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
        try await transcribe(
            recording: recording,
            store: store,
            trackMode: .preferred,
            progress: progress,
            liveUpdate: liveUpdate
        )
    }

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        trackMode: TranscriptionTrackMode,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void,
        liveUpdate: @escaping @Sendable (TranscriptionLiveSnapshot) -> Void
    ) async throws -> Transcript {
        guard !isResetting else { throw ModelOperationError.inUse }
        beginOperation()
        defer { endOperation() }
        await acquireTranscriptionTurn()
        defer { releaseTranscriptionTurn() }

        let cancellation = TranscriptionCancellationFlag()
        return try await withTaskCancellationHandler {
            try await transcribeInternal(
                recording: recording,
                store: store,
                trackMode: trackMode,
                cancellation: cancellation,
                progress: progress,
                liveUpdate: liveUpdate
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func beginOperation() {
        activeOperations += 1
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func endOperation() {
        activeOperations = max(0, activeOperations - 1)
        if activeOperations == 0, loadedWhisper != nil {
            scheduleIdleUnload()
        }
    }

    private func acquireTranscriptionTurn() async {
        guard isTranscribing else {
            isTranscribing = true
            return
        }
        await withCheckedContinuation { continuation in
            transcriptionWaiters.append(continuation)
        }
    }

    private func releaseTranscriptionTurn() {
        if transcriptionWaiters.isEmpty {
            isTranscribing = false
        } else {
            transcriptionWaiters.removeFirst().resume()
        }
    }

    private func transcribeInternal(
        recording: Recording,
        store: RecordingStore,
        trackMode: TranscriptionTrackMode,
        cancellation: TranscriptionCancellationFlag,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void,
        liveUpdate: @escaping @Sendable (TranscriptionLiveSnapshot) -> Void
    ) async throws -> Transcript {
        try checkCancellation(cancellation)
        let overallStart = ProcessInfo.processInfo.systemUptime
        let plan = try await resolvePlan(recording: recording, store: store, trackMode: trackMode)
        let duration = plan.timelineDuration
        guard duration.isFinite, duration > 0 else {
            throw RecordingTranscriptionError.invalidDuration
        }

        progress(.init(stage: .preparingModel, fractionCompleted: 0))
        Self.logger.notice("Transcription started: \(duration, format: .fixed(precision: 1)) s of audio")
        let resources = try await modelManager.ensureResourcesAvailable { fraction in
            progress(.init(stage: .preparingModel, fractionCompleted: Self.clamped(fraction)))
        }
        try checkCancellation(cancellation)
        Self.logger.notice("Transcription resources ready after \(ProcessInfo.processInfo.systemUptime - overallStart, format: .fixed(precision: 1)) s")

        let whisper: WhisperKit
        do {
            whisper = try await engine(resources: resources, progress: progress)
        } catch {
            try checkCancellation(cancellation)
            loadedWhisper = nil
            try await modelManager.reset()
            let repairedResources = try await modelManager.ensureResourcesAvailable { fraction in
                progress(.init(stage: .preparingModel, fractionCompleted: Self.clamped(fraction)))
            }
            whisper = try await engine(resources: repairedResources, progress: progress)
        }
        try checkCancellation(cancellation)
        progress(.init(stage: .transcribing, fractionCompleted: 0))
        Self.logger.notice("Whisper is listening after \(ProcessInfo.processInfo.systemUptime - overallStart, format: .fixed(precision: 1)) s")

        let options = Self.decodingOptions(for: performanceProfile)
        let audioInputOptions = Self.audioInputOptions(for: performanceProfile)
        let liveBuffer = TranscriptionLiveBuffer(
            recordingID: recording.id,
            audioDuration: duration,
            passCount: plan.passes.count
        )
        let provisionalRateLimiter = TranscriptionLiveRateLimiter()
        liveUpdate(liveBuffer.snapshot())

        let previousSegmentDiscoveryCallback = whisper.segmentDiscoveryCallback
        defer {
            whisper.segmentDiscoveryCallback = previousSegmentDiscoveryCallback
        }

        var results: [TranscriptionResult] = []
        var segmentsBySource: [TranscriptSource?: [TranscriptSegment]] = [:]
        var isAcousticEcho: @Sendable (TranscriptSegment) -> Bool = { _ in false }
        for (index, pass) in plan.passes.enumerated() {
            try checkCancellation(cancellation)
            liveUpdate(liveBuffer.beginPass(index))

            // The Mac's audio is heard first, so the microphone's echo of it stays out
            // of the live view as well as the result, and the microphone is decoded in
            // the conversation's language: a quiet echo is otherwise easily taken for
            // English and translated.
            var passOptions = options
            let isEcho: @Sendable (TranscriptSegment) -> Bool
            if pass.source == .microphone {
                let heardOnSystem = segmentsBySource[.system] ?? []
                isAcousticEcho = await Self.acousticEchoCheck(for: plan)
                let acoustic = isAcousticEcho
                isEcho = { TrackTranscriptMerger.isEcho($0, of: heardOnSystem) || acoustic($0) }
                if let language = Self.dominantLanguage(of: heardOnSystem) {
                    passOptions.language = language
                    passOptions.detectLanguage = false
                }
            } else {
                isEcho = { _ in false }
            }

            whisper.segmentDiscoveryCallback = { discoveredSegments in
                let converted = discoveredSegments
                    .compactMap { Self.segment(from: $0, in: pass) }
                    .filter { !isEcho($0) }
                guard !converted.isEmpty else { return }
                let snapshot = liveBuffer.merge(converted)
                liveUpdate(snapshot)
                progress(.init(stage: .transcribing, fractionCompleted: snapshot.fractionCompleted))
            }

            let passResults = try await whisper.transcribe(
                audioPath: pass.url.path,
                audioInputOptions: audioInputOptions,
                decodeOptions: passOptions,
                callback: { update in
                    if cancellation.isCancelled {
                        return false
                    }

                    let snapshot = liveBuffer.updateProvisionalText(update.text)
                    if snapshot.segments.isEmpty,
                       !snapshot.provisionalText.isEmpty,
                       provisionalRateLimiter.shouldEmit() {
                        liveUpdate(snapshot)
                    }
                    return true
                }
            )
            try checkCancellation(cancellation)
            results += passResults
            segmentsBySource[pass.source] = passResults.flatMap { result in
                result.segments.compactMap { Self.segment(from: $0, in: pass) }
            }
        }
        progress(.init(stage: .transcribing, fractionCompleted: 1))

        let speakers: [Speaker]
        let segments: [TranscriptSegment]
        if plan.isPerTrack {
            (segments, speakers) = TrackTranscriptMerger.merge(
                system: segmentsBySource[.system] ?? [],
                microphone: segmentsBySource[.microphone] ?? [],
                isAcousticEcho: isAcousticEcho
            )
        } else {
            speakers = []
            segments = (segmentsBySource[nil] ?? []).sorted {
                if $0.startTime == $1.startTime { return $0.id.uuidString < $1.id.uuidString }
                return $0.startTime < $1.startTime
            }
        }
        guard !segments.isEmpty else { throw RecordingTranscriptionError.emptyTranscription }

        // Whisper's own label can name the language of an early, nearly silent window;
        // the recognised text says which language the conversation was in.
        let language = Self.dominantLanguage(of: segments) ?? results.lazy.map(\.language).first { !$0.isEmpty }
        let selection = await modelManager.selectedSelection()
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - overallStart)
        let transcript = Transcript(
            recordingID: recording.id,
            languageCode: language,
            speakers: speakers,
            segments: segments,
            metadata: TranscriptMetadata(
                engine: "WhisperKit",
                engineVersion: Self.engineVersion,
                modelID: selection.modelID,
                selection: selection,
                processingDuration: elapsed,
                trackMode: plan.trackMode
            )
        )

        let timings = results.map(\.timings)
        let fallbackCount = Int(timings.reduce(0) { $0 + $1.totalDecodingFallbacks })
        let windowCount = Int(timings.reduce(0) { $0 + $1.totalDecodingWindows })
        lastMetrics = WhisperTranscriptionMetrics(
            audioSeconds: duration,
            asrSeconds: elapsed,
            asrRealTimeFactor: elapsed / duration,
            segmentCount: transcript.segments.count,
            wordCount: transcript.segments.reduce(0) { $0 + $1.words.count },
            incrementalChunkDurationSeconds: performanceProfile.incrementalChunkDurationSeconds,
            maxBufferedChunks: performanceProfile.maxBufferedChunks,
            workerCount: performanceProfile.concurrentWorkerCount,
            fallbackCount: fallbackCount,
            vadWindowCount: windowCount
        )
        Self.logger.info(
            "Whisper metrics audioSeconds=\(duration) ASRSeconds=\(elapsed) ASR_RTF=\(elapsed / duration) segments=\(transcript.segments.count) words=\(transcript.segments.reduce(0) { $0 + $1.words.count }) workers=\(self.performanceProfile.concurrentWorkerCount) incrementalChunkSeconds=\(self.performanceProfile.incrementalChunkDurationSeconds) bufferedChunks=\(self.performanceProfile.maxBufferedChunks) fallbackCount=\(fallbackCount) vadWindows=\(windowCount)"
        )
        return transcript
    }

    /// Compares the microphone's loudness with the Mac's audio; without readable audio
    /// only the words are compared.
    private nonisolated static func acousticEchoCheck(for plan: TranscriptionPlan) async -> @Sendable (TranscriptSegment) -> Bool {
        guard let system = plan.passes.first(where: { $0.source == .system }),
              let microphone = plan.passes.first(where: { $0.source == .microphone }) else {
            return { _ in false }
        }
        let measured = await Task.detached(priority: .userInitiated) { () -> (TrackLoudness, TrackLoudness)? in
            guard let systemLoudness = try? TrackLoudness.measure(url: system.url, duration: system.duration, offset: system.offset),
                  let microphoneLoudness = try? TrackLoudness.measure(url: microphone.url, duration: microphone.duration, offset: microphone.offset)
            else { return nil }
            return (microphoneLoudness, systemLoudness)
        }.value
        guard let (microphoneLoudness, systemLoudness) = measured else {
            logger.notice("Echo check by sound unavailable; comparing words only")
            return { _ in false }
        }
        return { TrackEchoDetector.isEcho($0, microphone: microphoneLoudness, system: systemLoudness) }
    }

    /// The language most of the text is in, as a Whisper language code.
    nonisolated static func dominantLanguage(of segments: [TranscriptSegment]) -> String? {
        let text = segments.map(\.text).joined(separator: " ")
        guard text.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6 else { return nil }
        return String(language.rawValue.prefix { $0 != "-" })
    }

    /// One WhisperKit segment placed on the recording's timeline and tagged with its track.
    private nonisolated static func segment(from segment: TranscriptionSegment, in pass: TranscriptionPass) -> TranscriptSegment? {
        let text = TranscriptTextSanitizer.normalizeRecognizedText(segment.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let words = (segment.words ?? []).map {
            TranscriptWord(
                startTime: TimeInterval($0.start) + pass.offset,
                endTime: TimeInterval($0.end) + pass.offset,
                text: $0.word,
                probability: $0.probability
            )
        }
        return TranscriptSegment(
            startTime: TimeInterval(segment.start) + pass.offset,
            endTime: TimeInterval(segment.end) + pass.offset,
            text: text,
            words: words,
            source: pass.source
        )
    }

    /// A window whose text compresses this well is a repetition loop. Whisper's default
    /// (2.4) also flags ordinary conversation that repeats a phrase; the temperature
    /// fallback it then triggers dropped whole turns at random (2–13 of 24 turns in a
    /// 187 s test dialogue). Real loops compress far beyond 3.5.
    static let repetitionCompressionRatioThreshold: Float = 3.5

    /// Decoding settings for every transcription.
    ///
    /// No prompt tokens: conditioning the decoder on a vocabulary prompt made Whisper
    /// skip the opening of each window and shift every later timestamp (a 25 s Spanish
    /// conversation lost its first 13 s). Product terms are normalized after recognition
    /// by `TranscriptTextSanitizer` instead.
    nonisolated static func decodingOptions(for profile: WhisperPerformanceProfile) -> DecodingOptions {
        var options = DecodingOptions(
            temperatureFallbackCount: profile.temperatureFallbackCount,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            wordTimestamps: true,
            concurrentWorkerCount: profile.concurrentWorkerCount,
            chunkingStrategy: profile.usesVAD ? .vad : nil
        )
        options.compressionRatioThreshold = repetitionCompressionRatioThreshold
        return options
    }

    nonisolated static func audioInputOptions(for profile: WhisperPerformanceProfile) -> AudioInputOptions {
        AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental(
                chunkDurationSeconds: profile.incrementalChunkDurationSeconds,
                maxBufferedChunks: profile.maxBufferedChunks
            )
        )
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
        Self.logger.notice("Loading the Whisper model; the first load on a Mac compiles it for the Neural Engine")
        let load: Task<LoadedWhisperEngine, Error>
        if let engineLoad {
            load = engineLoad
        } else {
            let modelFolder = resources.modelFolder.path
            let tokenizerFolder = resources.tokenizerFolder
            load = Task.detached(priority: .userInitiated) {
                let config = WhisperKitConfig(
                    model: nil,
                    modelFolder: modelFolder,
                    tokenizerFolder: tokenizerFolder,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: false
                )
                return LoadedWhisperEngine(try await WhisperKit(config))
            }
            engineLoad = load
            Task { [weak self] in
                let engine = try? await load.value
                await self?.engineLoadFinished(load, engine: engine)
            }
        }

        // Loading is not interrupted for one impatient caller: others may share it, and
        // a finished load is kept warm by `engineLoadFinished`.
        let engine = try await CancellableAwait.value(of: load, cancelUnderlyingTask: false)
        engineLoadFinished(load, engine: engine)
        Self.logger.notice("Whisper model ready in \(ProcessInfo.processInfo.systemUptime - loadStart, format: .fixed(precision: 1)) s")
        progress(.init(stage: .loadingModel, fractionCompleted: 1))
        return loadedWhisper ?? engine.whisper
    }

    private func engineLoadFinished(_ load: Task<LoadedWhisperEngine, Error>, engine: LoadedWhisperEngine?) {
        guard engineLoad == load else { return }
        engineLoad = nil
        if let engine, loadedWhisper == nil {
            loadedWhisper = engine.whisper
        }
        if activeOperations == 0, loadedWhisper != nil {
            scheduleIdleUnload()
        }
    }

    /// What to listen to: both original tracks apart when asked and both are readable,
    /// otherwise the single track Bardo has always transcribed.
    private func resolvePlan(
        recording: Recording,
        store: RecordingStore,
        trackMode: TranscriptionTrackMode
    ) async throws -> TranscriptionPlan {
        let isDualCapture = recording.sources.contains(.systemAudio)
            && recording.sources.contains(.microphone)

        if let tracks = TranscriptionAudioSelection.separateTracks(for: recording, mode: trackMode),
           let system = try? await store.managedAudioURL(recordingID: recording.id, audioAssetID: tracks.system.id),
           let microphone = try? await store.managedAudioURL(recordingID: recording.id, audioAssetID: tracks.microphone.id),
           tracks.system.metadata.duration > 0,
           tracks.microphone.metadata.duration > 0 {
            let passes = [
                TranscriptionPass(url: system, duration: tracks.system.metadata.duration, offset: tracks.system.timelineOffset, source: .system),
                TranscriptionPass(url: microphone, duration: tracks.microphone.metadata.duration, offset: tracks.microphone.timelineOffset, source: .microphone)
            ]
            let timeline = recording.duration ?? passes.map { $0.offset + $0.duration }.max() ?? 0
            return TranscriptionPlan(passes: passes, timelineDuration: timeline, trackMode: .perTrack)
        }

        let (url, duration) = try await resolveAudio(recording: recording, store: store)
        return TranscriptionPlan(
            passes: [TranscriptionPass(url: url, duration: duration, offset: 0, source: nil)],
            timelineDuration: duration,
            trackMode: isDualCapture ? .mix : nil
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

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadNanoseconds
        idleUnloadTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.unloadEngineAfterIdleTimeout()
        }
    }

    private func unloadEngineAfterIdleTimeout() async {
        idleUnloadTask = nil
        guard activeOperations == 0, !isTranscribing, let whisper = loadedWhisper else { return }
        loadedWhisper = nil
        await whisper.unloadModels()
    }

    private func checkCancellation(_ cancellation: TranscriptionCancellationFlag) throws {
        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
    }

    nonisolated private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}
