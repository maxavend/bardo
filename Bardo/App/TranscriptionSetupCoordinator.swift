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
    private(set) var completedSetupThisLaunch = false

    private let defaults: UserDefaults
    private var isPreparing = false

    private static var completionKey: String {
        "Bardo.FullAISetup.v4.\(SpeakerDiarizationService.modelID)"
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
            let transcription = try BardoTranscriptionService.live()
            let speakers = try SpeakerDiarizationService.live()
            let markedComplete = defaults.bool(forKey: Self.completionKey)
            let speakersInstalled = await speakers.hasInstalledModels()

            // Quality changes are intentionally on-demand. Once first-run setup has
            // completed, a newly selected transcription model must never block launch.
            // We warm it when already installed and download it only when the user asks
            // for it or starts a transcription.
            if !force, markedComplete, speakersInstalled {
                state = .ready
                async let transcriptionWarm: Void = transcription.warmUpIfInstalled(
                    for: TranscriptionQuality.current
                )
                async let speakerWarm: Void = speakers.warmUpIfInstalled()
                _ = await (transcriptionWarm, speakerWarm)
                return
            }

            completedSetupThisLaunch = false
            defaults.set(false, forKey: Self.completionKey)
            state = .checking

            try await transcription.prepareForUse(
                quality: TranscriptionQuality.current
            ) { [weak self] snapshot in
                Task { @MainActor in
                    self?.state = .installing(snapshot)
                }
            }

            try await speakers.prepareForUse { [weak self] snapshot in
                Task { @MainActor in
                    self?.state = .installingSpeakers(snapshot)
                }
            }

            await transcription.warmUpIfInstalled(for: TranscriptionQuality.current)

            defaults.set(true, forKey: Self.completionKey)
            completedSetupThisLaunch = true
            state = .ready
        } catch is CancellationError {
            // Closing Bardo during first-run setup is safe. Partial downloads remain in
            // local caches and the next launch resumes/validates them before Library.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() {
        Task { @MainActor in
            await prepareIfNeeded(force: true)
        }
    }

    func warmForRecording() {
        guard isReady else { return }
        Task {
            guard let service = try? BardoTranscriptionService.live() else { return }
            await service.warmUpIfInstalled(for: TranscriptionQuality.current)
        }
    }
}
