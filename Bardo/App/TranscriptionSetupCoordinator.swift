import Combine
import Foundation

@MainActor
final class TranscriptionSetupCoordinator: ObservableObject {
    enum State: Equatable {
        case checking
        case installing(TranscriptionSetupProgressSnapshot)
        case installingSpeakers(DiarizationSetupProgressSnapshot)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private let defaults: UserDefaults
    private var isPreparing = false

    private static var completionKey: String {
        "Bardo.FullAISetup.v2.\(TranscriptionModelManager.defaultModelID).\(SpeakerDiarizationService.modelID)"
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
        defer { isPreparing = false }

        do {
            let transcription = try WhisperTranscriptionService.live()
            let markedComplete = defaults.bool(forKey: Self.completionKey)

            if !force, markedComplete, await transcription.hasInstalledModel() {
                // Later launches enter Library immediately, then reload the already-installed
                // AI runtimes in the background. First-run setup has already paid all downloads.
                state = .ready
                async let transcriptionWarm: Void = transcription.warmUpIfInstalled()
                async let speakerWarm: Void = warmSpeakerRuntime()
                _ = await (transcriptionWarm, speakerWarm)
                return
            }

            defaults.set(false, forKey: Self.completionKey)
            state = .checking

            try await transcription.prepareForUse { [weak self] snapshot in
                Task { @MainActor in
                    self?.state = .installing(snapshot)
                }
            }

            let speakers = try SpeakerDiarizationService.live()
            try await speakers.prepareForUse { [weak self] snapshot in
                Task { @MainActor in
                    self?.state = .installingSpeakers(snapshot)
                }
            }

            defaults.set(true, forKey: Self.completionKey)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() {
        Task { @MainActor in
            await prepareIfNeeded(force: true)
        }
    }

    /// Re-warm the installed transcription runtime when a long capture starts so its
    /// eventual transcript is less likely to pay a cold Core ML load after recording ends.
    func warmForRecording() {
        guard isReady else { return }
        Task {
            guard let service = try? WhisperTranscriptionService.live() else { return }
            await service.warmUpIfInstalled()
        }
    }

    private func warmSpeakerRuntime() async {
        guard let speakers = try? SpeakerDiarizationService.live() else { return }
        try? await speakers.prepareForUse { _ in }
    }
}
