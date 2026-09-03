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
        "Bardo.FullAISetup.v4.\(TranscriptionModelManager.balancedModelID).\(TranscriptionModelManager.maximumAccuracyModelID).\(TranscriptionBackend.parakeetModelID).\(SpeakerDiarizationService.modelID).\(QwenMeetingMinutesModel.modelID)"
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
            let store = try BardoModelStore.live()
            let balanced = try WhisperTranscriptionService.live(for: .balanced)
            let maximumAccuracy = try WhisperTranscriptionService.live(for: .maximumAccuracy)
            let parakeet = try ParakeetTranscriptionService.live()
            let speakers = try SpeakerDiarizationService.live()
            let minutes = try QwenMeetingMinutesGenerator.live()
            let markedComplete = defaults.bool(forKey: Self.completionKey)

            let balancedInstalled = await balanced.hasInstalledModel()
            let maximumAccuracyInstalled = await maximumAccuracy.hasInstalledModel()
            let parakeetInstalled = await parakeet.hasInstalledModel()
            let speakersInstalled = await speakers.hasInstalledModels()
            let minutesInstalled = QwenMeetingMinutesModel.isInstalled(at: store.root(for: .qwen))
            let allModelsInstalled = balancedInstalled
                && maximumAccuracyInstalled
                && parakeetInstalled
                && speakersInstalled
                && minutesInstalled

            if !force, markedComplete, allModelsInstalled {
                try await prepareTranscriptionModels(
                    balanced: balanced,
                    maximumAccuracy: maximumAccuracy,
                    parakeet: parakeet
                )
                try await prepareMinutes(minutes)
                try await prepareSpeakers(speakers)
                state = .ready
                return
            }

            completedSetupThisLaunch = false
            defaults.set(false, forKey: Self.completionKey)
            state = .checking

            try await prepareTranscriptionModels(
                balanced: balanced,
                maximumAccuracy: maximumAccuracy,
                parakeet: parakeet
            )
            try await prepareMinutes(minutes)
            try await prepareSpeakers(speakers)

            // Keep the selected transcription path hot after the other local models finish.
            await warmSelectedTranscriptionModel()

            defaults.set(true, forKey: Self.completionKey)
            completedSetupThisLaunch = true
            state = .ready
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func prepareTranscriptionModels(
        balanced: WhisperTranscriptionService,
        maximumAccuracy: WhisperTranscriptionService,
        parakeet: ParakeetTranscriptionService
    ) async throws {
        try await balanced.prepareForUse { [weak self] snapshot in
            Task { @MainActor in self?.state = .installing(snapshot) }
        }
        try await maximumAccuracy.prepareForUse { [weak self] snapshot in
            Task { @MainActor in self?.state = .installing(snapshot) }
        }
        try await parakeet.prepareForUse { [weak self] snapshot in
            Task { @MainActor in self?.state = .installing(snapshot) }
        }
    }

    private func prepareMinutes(_ minutes: QwenMeetingMinutesGenerator) async throws {
        try await minutes.prepareForUse { [weak self] fraction in
            Task { @MainActor in
                self?.state = .installing(.init(stage: .optimizingForMac, fractionCompleted: fraction))
            }
        }
    }

    private func prepareSpeakers(_ speakers: SpeakerDiarizationService) async throws {
        try await speakers.prepareForUse { [weak self] snapshot in
            Task { @MainActor in self?.state = .installingSpeakers(snapshot) }
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
                for model in ManagedModel.allCases where model != .speakerKit {
                    try store.reset(model)
                }
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
            await warmSelectedTranscriptionModel()
        }
    }

    private func warmSelectedTranscriptionModel() async {
        let preset = TranscriptionPreferenceStore().selectedPreset()
        let option = TranscriptionOption.option(for: preset)
        switch option.selection.backend {
        case .parakeet:
            guard let service = try? ParakeetTranscriptionService.live() else { return }
            await service.warmUpIfInstalled()
        case .whisperKit:
            guard let service = try? WhisperTranscriptionService.live(for: option.preset) else { return }
            await service.warmUpIfInstalled()
        }
    }
}
