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
        "Bardo.FullAISetup.v6.\(TranscriptionModelManager.modelID).\(SpeakerDiarizationService.modelID).\(MeetingMinutesModel.modelID)"
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
            try store.removeLegacyVoiceModelDirectories()
            let whisper = try WhisperTranscriptionService.live()
            let speakers = try SpeakerDiarizationService.live()
            let minutes = try MeetingMinutesModelManager.live()
            let markedComplete = defaults.bool(forKey: Self.completionKey)

            let whisperInstalled = await whisper.hasInstalledModel()
            let speakersInstalled = await speakers.hasInstalledModels()
            let minutesInstalled = MeetingMinutesModelResourceResolver.isInstalled()
            let allModelsInstalled = whisperInstalled && speakersInstalled && minutesInstalled

            if !force, markedComplete, allModelsInstalled {
                try await prepareTranscriptionModels(whisper: whisper)
                try await prepareMinutes(minutes)
                try await prepareSpeakers(speakers)
                state = .ready
                return
            }

            completedSetupThisLaunch = false
            defaults.set(false, forKey: Self.completionKey)
            state = .checking

            try await prepareTranscriptionModels(whisper: whisper)
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
        whisper: WhisperTranscriptionService
    ) async throws {
        try await whisper.prepareForUse { [weak self] snapshot in
            Task { @MainActor in self?.state = .installing(snapshot) }
        }
    }

    private func prepareMinutes(_ minutes: MeetingMinutesModelManager) async throws {
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
                try store.removeLegacyVoiceModelDirectories()
                try await WhisperTranscriptionService.live().reset()
                try await SpeakerDiarizationService.live().reset()
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
        guard let service = try? WhisperTranscriptionService.live() else { return }
        await service.warmUpIfInstalled()
    }
}
