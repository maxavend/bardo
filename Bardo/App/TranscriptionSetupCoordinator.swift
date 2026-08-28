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
        defer { isPreparing = false }

        do {
            let transcription = try WhisperTranscriptionService.live()
            let speakers = try SpeakerDiarizationService.live()
            let markedComplete = defaults.bool(forKey: Self.completionKey)

            let transcriptionInstalled = await transcription.hasInstalledModel()
            let speakersInstalled = await speakers.hasInstalledModels()

            if !force, markedComplete, transcriptionInstalled, speakersInstalled {
                state = .ready
                async let transcriptionWarm: Void = transcription.warmUpIfInstalled()
                async let speakerWarm: Void = speakers.warmUpIfInstalled()
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

            try await speakers.prepareForUse { [weak self] snapshot in
                Task { @MainActor in
                    self?.state = .installingSpeakers(snapshot)
                }
            }

            defaults.set(true, forKey: Self.completionKey)
            state = .ready
        } catch is CancellationError {
            // Closing Bardo during first-run setup is safe. Partial downloads remain in the
            // local caches and the next launch resumes/validates them before entering Library.
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
            guard let service = try? WhisperTranscriptionService.live() else { return }
            await service.warmUpIfInstalled()
        }
    }
}
