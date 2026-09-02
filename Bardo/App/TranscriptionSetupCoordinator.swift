import Combine
import Foundation

@MainActor
final class TranscriptionSetupCoordinator: ObservableObject {
    enum State: Equatable {
        case checking
        case installing(TranscriptionSetupProgressSnapshot)
        case installingSpeakers(DiarizationSetupProgressSnapshot)
        case ready
        case cancelled
        case failed(String)
    }

    @Published private(set) var state: State
    private(set) var completedSetupThisLaunch = false

    private let defaults: UserDefaults
    private var isPreparing = false
    private var preparationTask: Task<Void, Never>?

    private static var completionKey: String {
        "Bardo.FullAISetup.v3.\(TranscriptionModelManager.defaultModelID).\(SpeakerDiarizationService.modelID)"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.state = defaults.bool(forKey: Self.completionKey) ? .ready : .checking
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func prepareIfNeeded(force: Bool = false) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer {
            isPreparing = false
            preparationTask = nil
        }

        do {
            let transcription = try WhisperTranscriptionService.live()
            let speakers = try SpeakerDiarizationService.live()
            let markedComplete = defaults.bool(forKey: Self.completionKey)

            let transcriptionInstalled = await transcription.hasInstalledModel()
            let speakersInstalled = await speakers.hasInstalledModels()

            if !force, markedComplete, transcriptionInstalled, speakersInstalled {
                // A completion marker is only a hint. Validate both engines again so a
                // corrupted Core ML cache cannot put the launch screen into a false Ready
                // state after a background warm-up silently failed.
                try await transcription.prepareForUse { [weak self] snapshot in
                    Task { @MainActor in self?.state = .installing(snapshot) }
                }
                try await speakers.prepareForUse { [weak self] snapshot in
                    Task { @MainActor in self?.state = .installingSpeakers(snapshot) }
                }
                state = .ready
                return
            }

            completedSetupThisLaunch = false
            defaults.set(false, forKey: Self.completionKey)
            state = .checking

            try await transcription.prepareForUse { [weak self] snapshot in
                Task { @MainActor in
                    self?.state = .installing(snapshot)
                }
            }

            try await speakers.prepareForUse { [weak self] snapshot in
                Task { @MainActor in
                    self?.state = .installingSpeakers(snapshot)
                }
            }

            // SpeakerKit setup can take long enough that Whisper's idle timer may have moved
            // on. Touch the shared runtime once more so "Ready" really means the first
            // transcription starts from a hot engine.
            await transcription.warmUpIfInstalled()

            defaults.set(true, forKey: Self.completionKey)
            completedSetupThisLaunch = true
            state = .ready
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func startPreparation(force: Bool = false) {
        guard preparationTask == nil, !isPreparing else { return }
        preparationTask = Task { @MainActor [weak self] in
            await self?.prepareIfNeeded(force: force)
        }
    }

    func cancelPreparation() {
        preparationTask?.cancel()
        if isPreparing {
            state = .cancelled
        }
    }

    func resetAndRetry() {
        guard preparationTask == nil, !isPreparing else { return }
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try BardoModelStore.live()
                try store.reset(.whisperBalanced)
                let speakers = try SpeakerDiarizationService.live()
                try await speakers.reset()
                defaults.set(false, forKey: Self.completionKey)
                await prepareIfNeeded(force: true)
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = .failed(error.localizedDescription)
                preparationTask = nil
            }
        }
    }

    func retry() {
        startPreparation(force: true)
    }

    func warmForRecording() {
        guard isReady else { return }
        Task {
            guard let service = try? WhisperTranscriptionService.live() else { return }
            await service.warmUpIfInstalled()
        }
    }
}
