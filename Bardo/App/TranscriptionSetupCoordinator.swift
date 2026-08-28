import Foundation

@MainActor
final class TranscriptionSetupCoordinator: ObservableObject {
    enum State: Equatable {
        case checking
        case installing(TranscriptionSetupProgressSnapshot)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private let defaults: UserDefaults
    private var isPreparing = false

    private static var completionKey: String {
        "Bardo.TranscriptionSetupCompleted.\(TranscriptionModelManager.defaultModelID)"
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
            let service = try WhisperTranscriptionService.live()
            let markedComplete = defaults.bool(forKey: Self.completionKey)

            if !force, markedComplete, await service.hasInstalledModel() {
                // The app can appear immediately on subsequent launches. Warm the exact shared
                // runtime in the background so transcription is hot before the user needs it.
                state = .ready
                await service.warmUpIfInstalled()
                return
            }

            defaults.set(false, forKey: Self.completionKey)
            state = .checking

            try await service.prepareForUse { [weak self] snapshot in
                Task { @MainActor in
                    self?.state = .installing(snapshot)
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

    /// Recording can outlive the 10-minute idle residency window. Re-warm the installed
    /// model as capture begins so a long meeting still finishes with a hot transcription path.
    func warmForRecording() {
        guard isReady else { return }
        Task {
            guard let service = try? WhisperTranscriptionService.live() else { return }
            await service.warmUpIfInstalled()
        }
    }
}
