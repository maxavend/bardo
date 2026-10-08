import Combine
import Foundation

/// The model operations first-run setup relies on, abstracted so setup flows can be
/// tested without downloading or loading real models.
protocol TranscriptionSetupServices: Sendable {
    func removeLegacyModels() throws
    func isTranscriptionInstalled() async -> Bool
    func areSpeakersInstalled() async -> Bool
    func prepareTranscription(progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void) async throws
    func prepareSpeakers(progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void) async throws
    func warmUpTranscription() async
    func warmUpSpeakers() async
    func resetAll() async throws
}

struct LiveTranscriptionSetupServices: TranscriptionSetupServices {
    func removeLegacyModels() throws {
        try BardoModelStore.live().removeLegacyVoiceModelDirectories()
    }

    func isTranscriptionInstalled() async -> Bool {
        guard let service = try? WhisperTranscriptionService.live() else { return false }
        return await service.hasInstalledModel()
    }

    func areSpeakersInstalled() async -> Bool {
        guard let service = try? SpeakerDiarizationService.live() else { return false }
        return await service.hasInstalledModels()
    }

    func prepareTranscription(progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void) async throws {
        try await WhisperTranscriptionService.live().prepareForUse(progress: progress)
    }

    func prepareSpeakers(progress: @escaping @Sendable (DiarizationSetupProgressSnapshot) -> Void) async throws {
        try await SpeakerDiarizationService.live().prepareForUse(progress: progress)
    }

    func warmUpTranscription() async {
        await (try? WhisperTranscriptionService.live())?.warmUpIfInstalled()
    }

    func warmUpSpeakers() async {
        await (try? SpeakerDiarizationService.live())?.warmUpIfInstalled()
    }

    func resetAll() async throws {
        try? BardoModelStore.live().removeLegacyVoiceModelDirectories()
        try await WhisperTranscriptionService.live().reset()
        try await SpeakerDiarizationService.live().reset()
    }
}

@MainActor
final class TranscriptionSetupCoordinator: ObservableObject {
    enum State: Equatable {
        case checking
        case installing(TranscriptionSetupProgressSnapshot)
        case installingSpeakers(DiarizationSetupProgressSnapshot)
        case ready
        case cancelled
        case failed(String)
        /// Setup finished before, but the local models were removed since. Bardo asks
        /// before downloading them again.
        case needsInstall
    }

    @Published private(set) var state: State
    /// Once true the Library stays available, whatever happens to the local models.
    /// Recording, importing and playback never depend on transcription models.
    @Published private(set) var isLibraryUnlocked: Bool
    private(set) var completedSetupThisLaunch = false

    private let defaults: UserDefaults
    private let services: any TranscriptionSetupServices
    private var isPreparing = false
    private var preparationTask: Task<Void, Never>?

    private static var completionKey: String {
        "Bardo.TranscriptionSetup.v8.\(TranscriptionModelManager.modelID).\(SpeakerDiarizationService.modelID)"
    }

    static let libraryUnlockedKey = "Bardo.Setup.LibraryUnlocked.v1"

    init(
        defaults: UserDefaults = .standard,
        services: any TranscriptionSetupServices = LiveTranscriptionSetupServices()
    ) {
        self.defaults = defaults
        self.services = services
        let completed = defaults.bool(forKey: Self.completionKey)
        self.state = completed ? .ready : .checking
        self.isLibraryUnlocked = completed || defaults.bool(forKey: Self.libraryUnlockedKey)
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isWorking: Bool {
        switch state {
        case .checking, .installing, .installingSpeakers:
            return isPreparing
        case .ready, .cancelled, .failed, .needsInstall:
            return false
        }
    }

    /// Opens the Library while transcription models are missing or still installing.
    func unlockLibrary() {
        guard !isLibraryUnlocked else { return }
        isLibraryUnlocked = true
        defaults.set(true, forKey: Self.libraryUnlockedKey)
    }

    func prepareIfNeeded(force: Bool = false) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer {
            isPreparing = false
            preparationTask = nil
        }

        do {
            try? services.removeLegacyModels()
            let markedComplete = defaults.bool(forKey: Self.completionKey)

            let whisperInstalled = await services.isTranscriptionInstalled()
            let speakersInstalled = await services.areSpeakersInstalled()

            if !force, whisperInstalled, speakersInstalled {
                markCompleted()
                state = .ready
                await services.warmUpTranscription()
                await services.warmUpSpeakers()
                return
            }

            if !force, markedComplete {
                // The user removed the models (for example from Settings). Never start
                // a large download behind their back; offer it instead.
                state = .needsInstall
                return
            }

            completedSetupThisLaunch = false
            state = .checking

            try await services.prepareTranscription { [weak self] snapshot in
                Task { @MainActor in self?.publishProgress(.installing(snapshot)) }
            }
            try await services.prepareSpeakers { [weak self] snapshot in
                Task { @MainActor in self?.publishProgress(.installingSpeakers(snapshot)) }
            }
            await services.warmUpTranscription()

            markCompleted()
            completedSetupThisLaunch = true
            state = .ready
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = .failed(Self.friendlyMessage(for: error))
        }
    }

    /// Network failures surface from deep inside the model downloaders as raw
    /// `NSURLErrorDomain` codes; describe them in plain words.
    nonisolated static func friendlyMessage(for error: Error) -> String {
        let offlineCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut,
            NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed
        ]
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSURLErrorDomain {
                return offlineCodes.contains(nsError.code)
                    ? String(localized: "Bardo could not connect to the internet. Check your connection and try again.")
                    : String(localized: "The download was interrupted. Try again in a moment.")
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return error.localizedDescription
    }

    private func markCompleted() {
        defaults.set(true, forKey: Self.completionKey)
        unlockLibrary()
    }

    /// Progress hops to the main actor asynchronously; ignore reports that arrive after
    /// setup already finished, failed or was paused.
    private func publishProgress(_ progress: State) {
        guard isPreparing, preparationTask?.isCancelled != true else { return }
        state = progress
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
                try await services.resetAll()
                defaults.set(false, forKey: Self.completionKey)
                await prepareIfNeeded(force: true)
            } catch is CancellationError {
                state = .cancelled
                preparationTask = nil
            } catch {
                state = .failed(Self.friendlyMessage(for: error))
                preparationTask = nil
            }
        }
    }

    func retry() {
        startPreparation(force: true)
    }

    func warmForRecording() {
        guard isReady else { return }
        let services = services
        Task {
            await services.warmUpTranscription()
        }
    }
}
