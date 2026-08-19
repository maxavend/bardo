import Combine
import Foundation

@MainActor
final class MicrophoneRecordingController: ObservableObject {
    enum Phase: String, Equatable, Sendable {
        case idle
        case requestingPermission
        case preparing
        case recording
        case finalizing
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var permissionState: MicrophonePermissionState
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var inputDisplayName: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryIssues: [RecordingStoreIssue] = []

    var isRecording: Bool { phase == .recording }

    var isBusy: Bool {
        switch phase {
        case .requestingPermission, .preparing, .recording, .finalizing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var requiresTerminationFinalization: Bool {
        phase == .recording || phase == .finalizing
    }

    static var activeForApplicationTermination: MicrophoneRecordingController? {
        globalCaptureOwner
    }

    private struct Session {
        let recordingID: UUID
        let audioAssetID: UUID
        let startedAt: Date
        let stagingURL: URL
        let fileExtension: String
    }

    private static weak var globalCaptureOwner: MicrophoneRecordingController?

    private var store: RecordingStore?
    private var stagingStore: MicrophoneCaptureStagingStore?
    private let permissionAuthorizer: any MicrophonePermissionAuthorizing
    private let backend: any AudioCapturing
    private let metadataReader: AudioMetadataReader
    private let settingsOpener: MicrophoneSystemSettingsOpener
    private var session: Session?
    private var progressTask: Task<Void, Never>?

    init(
        store: RecordingStore? = nil,
        stagingStore: MicrophoneCaptureStagingStore? = nil,
        permissionAuthorizer: any MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer(),
        backend: any AudioCapturing = AVAudioRecorderCaptureBackend(),
        metadataReader: AudioMetadataReader = AudioMetadataReader(),
        settingsOpener: MicrophoneSystemSettingsOpener = MicrophoneSystemSettingsOpener()
    ) {
        self.store = store
        self.stagingStore = stagingStore
        self.permissionAuthorizer = permissionAuthorizer
        self.backend = backend
        self.metadataReader = metadataReader
        self.settingsOpener = settingsOpener
        permissionState = permissionAuthorizer.currentStatus()

        backend.eventHandler = { [weak self] event in
            self?.handleBackendEvent(event)
        }
    }

    func start() async {
        errorMessage = nil

        guard !isBusy else {
            errorMessage = "A microphone recording is already active or changing state."
            return
        }
        guard acquireGlobalCaptureLease() else {
            errorMessage = "Another Bardo recording is already using the microphone."
            return
        }

        let currentPermission = permissionAuthorizer.currentStatus()
        permissionState = currentPermission

        switch currentPermission {
        case .authorized:
            phase = .preparing
            await beginAuthorizedCapture()
        case .notDetermined:
            phase = .requestingPermission
            let requested = await permissionAuthorizer.requestAccess()
            permissionState = requested
            guard requested == .authorized else {
                phase = .idle
                presentPermissionMessage(for: requested)
                releaseGlobalCaptureLease()
                return
            }
            phase = .preparing
            await beginAuthorizedCapture()
        case .denied, .restricted, .error:
            phase = .idle
            presentPermissionMessage(for: currentPermission)
            releaseGlobalCaptureLease()
        }
    }

    @discardableResult
    func stop() async -> Recording? {
        guard phase == .recording, let session else { return nil }

        phase = .finalizing
        stopProgressUpdates()
        let capturedElapsed = max(elapsedTime, backend.currentTime)
        backend.stop()

        do {
            let store = try resolveStore()
            let stagingStore = try resolveStagingStore()
            let metadata = try metadataReader.read(from: session.stagingURL)
            let asset = AudioAsset(
                id: session.audioAssetID,
                originalFileName: "Microphone Recording.\(session.fileExtension)",
                fileExtension: session.fileExtension,
                metadata: metadata
            )
            let recording = Recording(
                id: session.recordingID,
                title: "Microphone Recording",
                createdAt: session.startedAt,
                duration: metadata.duration,
                sources: [.microphone],
                processingState: .pending,
                audioAssets: [asset]
            )

            // Reuse the certified Phase 2 publication transaction. The staging file is
            // the source; RecordingStore owns the final managed copy + manifest ordering.
            try await store.importRecording(recording, audioAsset: asset, from: session.stagingURL)

            do {
                try await stagingStore.discardPreparedCapture(recordingID: session.recordingID)
            } catch {
                // The recording is already safely published. Preserve cleanup residue and
                // surface it through recovery instead of invalidating a successful capture.
            }

            self.session = nil
            phase = .idle
            elapsedTime = 0
            inputDisplayName = nil
            errorMessage = nil
            releaseGlobalCaptureLease()
            await refreshRecoveryIssues()
            return recording
        } catch {
            await failAfterCapture(
                session: session,
                message: "The recording stopped, but Bardo could not safely publish it: \(error.localizedDescription)"
            )
            elapsedTime = capturedElapsed
            return nil
        }
    }

    func prepareForApplicationTermination() async {
        if phase == .recording {
            _ = await stop()
        }

        while phase == .finalizing {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func refreshPermissionState() {
        permissionState = permissionAuthorizer.currentStatus()
    }

    func refreshElapsedTime() {
        guard phase == .recording else { return }
        elapsedTime = max(0, backend.currentTime)
    }

    func refreshRecoveryIssues() async {
        do {
            recoveryIssues = try await resolveStagingStore().recoveryIssues()
        } catch {
            recoveryIssues = []
        }
    }

    func clearError() {
        errorMessage = nil
        if phase == .failed {
            phase = .idle
            elapsedTime = 0
            inputDisplayName = nil
        }
    }

    @discardableResult
    func openMicrophoneSystemSettings() -> Bool {
        settingsOpener.open()
    }

    private func beginAuthorizedCapture() async {
        let recordingID = UUID()
        let audioAssetID = UUID()
        let fileExtension = backend.fileExtension
        let startedAt = Date()

        do {
            _ = try resolveStore()
            let stagingStore = try resolveStagingStore()
            let stagingURL = try await stagingStore.prepareCapture(
                recordingID: recordingID,
                audioAssetID: audioAssetID,
                fileExtension: fileExtension
            )

            do {
                try backend.start(to: stagingURL)
            } catch {
                try? await stagingStore.discardPreparedCapture(recordingID: recordingID)
                throw error
            }

            session = Session(
                recordingID: recordingID,
                audioAssetID: audioAssetID,
                startedAt: startedAt,
                stagingURL: stagingURL,
                fileExtension: fileExtension
            )
            inputDisplayName = backend.inputDisplayName
            elapsedTime = max(0, backend.currentTime)
            phase = .recording
            startProgressUpdates()
        } catch {
            session = nil
            phase = .failed
            errorMessage = error.localizedDescription
            elapsedTime = 0
            inputDisplayName = nil
            releaseGlobalCaptureLease()
            await refreshRecoveryIssues()
        }
    }

    private func resolveStore() throws -> RecordingStore {
        if let store { return store }
        let liveStore = try RecordingStore.live()
        store = liveStore
        return liveStore
    }

    private func resolveStagingStore() throws -> MicrophoneCaptureStagingStore {
        if let stagingStore { return stagingStore }
        let liveStore = try MicrophoneCaptureStagingStore.live()
        stagingStore = liveStore
        return liveStore
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.phase == .recording else { return }
                self.refreshElapsedTime()
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func handleBackendEvent(_ event: AudioCaptureBackendEvent) {
        guard phase == .recording, let session else { return }

        stopProgressUpdates()
        elapsedTime = max(elapsedTime, backend.currentTime)
        backend.stop()
        self.session = nil
        phase = .failed
        releaseGlobalCaptureLease()

        switch event {
        case .interrupted(let message):
            errorMessage = "Microphone recording was interrupted: \(message)"
        }

        if let stagingStore {
            Task {
                await stagingStore.preserveInterruptedCapture(recordingID: session.recordingID)
                await self.refreshRecoveryIssues()
            }
        }
    }

    private func failAfterCapture(session: Session, message: String) async {
        stopProgressUpdates()
        self.session = nil
        phase = .failed
        errorMessage = message
        releaseGlobalCaptureLease()

        if let stagingStore {
            await stagingStore.preserveInterruptedCapture(recordingID: session.recordingID)
        }
        await refreshRecoveryIssues()
    }

    private func acquireGlobalCaptureLease() -> Bool {
        if let owner = Self.globalCaptureOwner, owner !== self {
            return false
        }
        Self.globalCaptureOwner = self
        return true
    }

    private func releaseGlobalCaptureLease() {
        if Self.globalCaptureOwner === self {
            Self.globalCaptureOwner = nil
        }
    }

    private func presentPermissionMessage(for state: MicrophonePermissionState) {
        switch state {
        case .notDetermined:
            errorMessage = "Microphone permission is still awaiting a response."
        case .authorized:
            errorMessage = nil
        case .denied:
            errorMessage = "Microphone access is denied. You can enable Bardo in System Settings → Privacy & Security → Microphone."
        case .restricted:
            errorMessage = "Microphone access is restricted by macOS and cannot be requested by Bardo."
        case .error(let message):
            errorMessage = message
        }
    }
}
