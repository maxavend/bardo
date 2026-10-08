import AppKit
import Combine
import Foundation

enum CapturePublicationError: Error, LocalizedError, Equatable, Sendable {
    case noAudioCaptured
    case alreadyInLibrary

    var errorDescription: String? {
        switch self {
        case .noAudioCaptured:
            return String(localized: "The capture does not contain any readable audio.")
        case .alreadyInLibrary:
            return String(localized: "This capture is already in your library. Its leftover copy was moved to the Trash.")
        }
    }
}

@MainActor
final class MicrophoneRecordingController: ObservableObject {
    enum Phase: String, Equatable, Sendable {
        case idle
        case requestingPermission
        case preparing
        case recording
        case paused
        case finalizing
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var permissionState: MicrophonePermissionState
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var inputDisplayName: String?
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryIssues: [RecordingStoreIssue] = []
    @Published private(set) var isRecovering = false

    /// Called on the main actor for every recording this controller adds to the
    /// Library: normal stops, interruptions that kept audio, and recoveries.
    var onRecordingPublished: ((Recording) -> Void)?

    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { phase == .paused }

    var isBusy: Bool {
        switch phase {
        case .requestingPermission, .preparing, .recording, .paused, .finalizing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var requiresTerminationFinalization: Bool {
        phase == .recording || phase == .paused || phase == .finalizing
    }

    static var activeForApplicationTermination: MicrophoneRecordingController? {
        globalCaptureOwner
    }

    static let defaultRecordingTitle = "Microphone Recording"

    private struct Session {
        let recordingID: UUID
        let audioAssetID: UUID
        let startedAt: Date
        let stagingURL: URL
        let title: String?
    }

    private static weak var globalCaptureOwner: MicrophoneRecordingController?

    private var store: RecordingStore?
    private var stagingStore: MicrophoneCaptureStagingStore?
    private let permissionAuthorizer: any MicrophonePermissionAuthorizing
    private let backend: any AudioCapturing
    private let metadataReader: AudioMetadataReader
    private let transcoder: any AudioTranscoding
    private let settingsOpener: MicrophoneSystemSettingsOpener
    private let captureLeaseID = UUID()
    private var session: Session?
    private var progressTask: Task<Void, Never>?

    init(
        store: RecordingStore? = nil,
        stagingStore: MicrophoneCaptureStagingStore? = nil,
        permissionAuthorizer: any MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer(),
        backend: any AudioCapturing = AVAudioRecorderCaptureBackend(),
        metadataReader: AudioMetadataReader = AudioMetadataReader(),
        transcoder: any AudioTranscoding = AACAudioTranscoder(),
        settingsOpener: MicrophoneSystemSettingsOpener = MicrophoneSystemSettingsOpener()
    ) {
        self.store = store
        self.stagingStore = stagingStore
        self.permissionAuthorizer = permissionAuthorizer
        self.backend = backend
        self.metadataReader = metadataReader
        self.transcoder = transcoder
        self.settingsOpener = settingsOpener
        permissionState = permissionAuthorizer.currentStatus()

        backend.eventHandler = { [weak self] event in
            self?.handleBackendEvent(event)
        }
    }

    func start(title: String? = nil) async {
        errorMessage = nil

        guard !isBusy, !isRecovering else {
            errorMessage = String(localized: "A microphone recording is already active or changing state.")
            return
        }
        guard acquireGlobalCaptureLease() else {
            errorMessage = String(localized: "Another Bardo recording is already active.")
            return
        }

        let currentPermission = permissionAuthorizer.currentStatus()
        permissionState = currentPermission

        switch currentPermission {
        case .authorized:
            phase = .preparing
            await beginAuthorizedCapture(title: title)
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
            await beginAuthorizedCapture(title: title)
        case .denied, .restricted, .error:
            phase = .idle
            presentPermissionMessage(for: currentPermission)
            releaseGlobalCaptureLease()
        }
    }

    func pause() {
        guard phase == .recording else { return }
        backend.pause()
        refreshElapsedTime()
        inputLevel = 0
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        backend.resume()
        phase = .recording
        startProgressUpdates()
    }

    @discardableResult
    func stop() async -> Recording? {
        guard (phase == .recording || phase == .paused), let session else { return nil }

        phase = .finalizing
        stopProgressUpdates()
        let capturedElapsed = max(elapsedTime, backend.currentTime)
        backend.stop()
        return await finalize(session, interruptionMessage: nil, capturedElapsed: capturedElapsed)
    }

    func prepareForApplicationTermination() async {
        if phase == .recording || phase == .paused {
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

    func discardRecoveryIssue(_ issue: RecordingStoreIssue) async {
        guard let recordingID = issue.recordingID else { return }
        do {
            try await resolveStagingStore().discardCapture(recordingID: recordingID)
            await refreshRecoveryIssues()
        } catch {
            errorMessage = String(localized: "Bardo could not discard \(issue.entryName): \(error.localizedDescription)")
        }
    }

    func moveRecoveryIssueToTrash(_ issue: RecordingStoreIssue) async {
        guard let recordingID = issue.recordingID else { return }
        do {
            try await resolveStagingStore().moveToTrash(recordingID: recordingID)
            await refreshRecoveryIssues()
        } catch {
            errorMessage = String(localized: "Bardo could not move \(issue.entryName) to the Trash: \(error.localizedDescription)")
        }
    }

    func moveAllRecoveryIssuesToTrash() async {
        let issuesToMove = recoveryIssues.compactMap { issue -> UUID? in
            issue.recordingID
        }
        guard !issuesToMove.isEmpty else { return }

        do {
            let store = try resolveStagingStore()
            for recordingID in issuesToMove {
                try await store.moveToTrash(recordingID: recordingID)
            }
            await refreshRecoveryIssues()
        } catch {
            errorMessage = String(localized: "Bardo could not move the recovery captures to the Trash: \(error.localizedDescription)")
        }
    }

    /// Publishes the readable audio of an interrupted capture into the Library.
    @discardableResult
    func recoverRecoveryIssue(_ issue: RecordingStoreIssue) async -> Recording? {
        guard let stagingID = issue.recordingID, !isBusy, !isRecovering else { return nil }
        isRecovering = true
        CaptureRecoveryActivity.begin()
        defer {
            isRecovering = false
            CaptureRecoveryActivity.end()
        }

        do {
            let stagingStore = try resolveStagingStore()
            let store = try resolveStore()
            guard let staged = await stagingStore.contents(recordingID: stagingID) else {
                await refreshRecoveryIssues()
                return nil
            }
            // A save that stopped halfway left the compressed audio in the Library folder.
            try await store.reclaimIncompletePublication(recordingID: stagingID, into: staged.directoryURL)

            if (try? await store.read(id: stagingID)) != nil {
                // The recording was saved; what remains is the lossless copy it was made
                // from. Keep it reachable in the Trash rather than deleting it.
                try? await stagingStore.moveToTrash(recordingID: stagingID)
                await refreshRecoveryIssues()
                errorMessage = CapturePublicationError.alreadyInLibrary.localizedDescription
                return nil
            }

            guard let contents = await stagingStore.contents(recordingID: stagingID),
                  let audioURL = preferredRecoverableAudio(in: contents) else {
                throw CapturePublicationError.noAudioCaptured
            }
            let audioAssetID = contents.manifest?.microphoneAssetID
                ?? UUID(uuidString: audioURL.deletingPathExtension().lastPathComponent)
                ?? UUID()

            let recordingID = await store.recordingDirectoryExists(recordingID: stagingID) ? UUID() : stagingID
            let recording = try await publishStagedAudio(
                recordingID: recordingID,
                audioAssetID: audioAssetID,
                stagingURL: audioURL,
                title: contents.manifest?.title,
                startedAt: contents.startedAt
            )
            // When the staged PCM was compressed, the published file is the compressed
            // copy and the PCM source is no longer needed.
            if FileManager.default.fileExists(atPath: audioURL.path) {
                try? FileManager.default.removeItem(at: audioURL)
            }
            try? await stagingStore.finishRecovery(recordingID: stagingID, reader: metadataReader)
            await refreshRecoveryIssues()
            onRecordingPublished?(recording)
            return recording
        } catch {
            errorMessage = String(localized: "Bardo could not recover \(issue.entryName): \(error.localizedDescription)")
            await refreshRecoveryIssues()
            return nil
        }
    }

    @discardableResult
    func openRecoveryFolder() -> Bool {
        guard let root = try? MicrophoneCaptureStagingStore.liveRootURL() else { return false }
        return NSWorkspace.shared.open(root)
    }

    func clearError() {
        errorMessage = nil
        if phase == .failed {
            phase = .idle
            elapsedTime = 0
            inputDisplayName = nil
            inputLevel = 0
        }
    }

    @discardableResult
    func openMicrophoneSystemSettings() -> Bool {
        settingsOpener.open()
    }

    private func beginAuthorizedCapture(title: String?) async {
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
                fileExtension: fileExtension,
                title: title,
                startedAt: startedAt
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
                title: title
            )
            inputDisplayName = backend.inputDisplayName
            elapsedTime = max(0, backend.currentTime)
            inputLevel = backend.inputLevel
            phase = .recording
            startProgressUpdates()
        } catch {
            session = nil
            phase = .failed
            errorMessage = error.localizedDescription
            elapsedTime = 0
            inputDisplayName = nil
            inputLevel = 0
            releaseGlobalCaptureLease()
            await refreshRecoveryIssues()
        }
    }

    /// Publishes the staged capture, or preserves it for recovery when that fails.
    private func finalize(
        _ session: Session,
        interruptionMessage: String?,
        capturedElapsed: TimeInterval
    ) async -> Recording? {
        do {
            let recording = try await publishStagedAudio(
                recordingID: session.recordingID,
                audioAssetID: session.audioAssetID,
                stagingURL: session.stagingURL,
                title: session.title,
                startedAt: session.startedAt
            )

            do {
                try await resolveStagingStore().discardCapture(recordingID: session.recordingID)
            } catch {
                // The recording is already safely published. Preserve cleanup residue and
                // surface it through recovery instead of invalidating a successful capture.
            }

            self.session = nil
            phase = .idle
            elapsedTime = 0
            inputDisplayName = nil
            inputLevel = 0
            errorMessage = interruptionMessage.map {
                String(localized: "Microphone recording was interrupted: \($0) Bardo saved the audio captured until then.")
            }
            releaseGlobalCaptureLease()
            await refreshRecoveryIssues()
            onRecordingPublished?(recording)
            return recording
        } catch CapturePublicationError.noAudioCaptured {
            try? await resolveStagingStore().discardCapture(recordingID: session.recordingID)
            self.session = nil
            phase = .failed
            elapsedTime = 0
            inputDisplayName = nil
            inputLevel = 0
            errorMessage = interruptionMessage.map { String(localized: "Microphone recording was interrupted: \($0)") }
                ?? String(localized: "The recording ended before any audio was captured.")
            releaseGlobalCaptureLease()
            await refreshRecoveryIssues()
            return nil
        } catch {
            let detail = interruptionMessage.map { String(localized: "Microphone recording was interrupted: \($0) ") } ?? ""
            await failAfterCapture(
                session: session,
                message: String(localized: "\(detail)The recording stopped, but Bardo could not safely publish it: \(error.localizedDescription) It was kept for recovery.")
            )
            elapsedTime = capturedElapsed
            return nil
        }
    }

    private func publishStagedAudio(
        recordingID: UUID,
        audioAssetID: UUID,
        stagingURL: URL,
        title: String?,
        startedAt: Date
    ) async throws -> Recording {
        let store = try resolveStore()

        let sourceMetadata: AudioMetadata
        do {
            sourceMetadata = try metadataReader.read(from: stagingURL)
        } catch {
            if Self.isEffectivelyEmpty(stagingURL) {
                throw CapturePublicationError.noAudioCaptured
            }
            throw error
        }

        var publishURL = stagingURL
        var metadata = sourceMetadata
        if stagingURL.pathExtension.lowercased() != "m4a" {
            let compactURL = stagingURL.deletingPathExtension().appendingPathExtension("m4a")
            do {
                try await transcoder.transcodeToCompactM4A(from: stagingURL, to: compactURL)
                metadata = try metadataReader.read(from: compactURL)
                publishURL = compactURL
            } catch {
                // Keep the lossless staging file rather than risking the recording.
                try? FileManager.default.removeItem(at: compactURL)
                metadata = sourceMetadata
                publishURL = stagingURL
            }
        }

        let fileExtension = publishURL.pathExtension.lowercased()
        let asset = AudioAsset(
            id: audioAssetID,
            originalFileName: "\(Self.defaultRecordingTitle).\(fileExtension)",
            fileExtension: fileExtension,
            metadata: metadata,
            role: .microphoneOriginal
        )
        let recording = Recording(
            id: recordingID,
            title: title ?? Self.defaultRecordingTitle,
            createdAt: startedAt,
            duration: metadata.duration,
            sources: [.microphone],
            processingState: .pending,
            audioAssets: [asset]
        )

        try await store.importRecording(
            recording,
            audioAsset: asset,
            from: publishURL,
            transferringOwnership: true
        )
        return recording
    }

    /// Prefers lossless staging audio, which can be compressed again, over a leftover
    /// compressed copy from an earlier attempt.
    private func preferredRecoverableAudio(in contents: StagedCaptureContents) -> URL? {
        let preference = ["caf": 0, "wav": 1, "aiff": 2, "aif": 2, "m4a": 3]
        return contents.audioFiles
            .sorted { (preference[$0.pathExtension.lowercased()] ?? 9) < (preference[$1.pathExtension.lowercased()] ?? 9) }
            .first { (try? metadataReader.read(from: $0)) != nil }
    }

    /// A staged file this small holds at most a header: there is no audio to keep.
    nonisolated static func isEffectivelyEmpty(_ url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return true }
        return size < 16_384
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
                self.inputLevel = self.backend.inputLevel
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
        inputLevel = 0
    }

    private func handleBackendEvent(_ event: AudioCaptureBackendEvent) {
        guard phase == .recording || phase == .paused, let session else { return }

        stopProgressUpdates()
        let capturedElapsed = max(elapsedTime, backend.currentTime)
        elapsedTime = capturedElapsed
        backend.stop()
        phase = .finalizing

        let message: String
        switch event {
        case .interrupted(let detail):
            message = detail
        }

        Task { @MainActor [weak self] in
            _ = await self?.finalize(session, interruptionMessage: message, capturedElapsed: capturedElapsed)
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
        guard RecordingCaptureLease.acquire(ownerID: captureLeaseID) else { return false }
        Self.globalCaptureOwner = self
        return true
    }

    private func releaseGlobalCaptureLease() {
        RecordingCaptureLease.release(ownerID: captureLeaseID)
        if Self.globalCaptureOwner === self {
            Self.globalCaptureOwner = nil
        }
    }

    private func presentPermissionMessage(for state: MicrophonePermissionState) {
        switch state {
        case .notDetermined:
            errorMessage = String(localized: "Microphone permission is still awaiting a response.")
        case .authorized:
            errorMessage = nil
        case .denied:
            errorMessage = String(localized: "Microphone access is denied. You can enable Bardo in System Settings → Privacy & Security → Microphone.")
        case .restricted:
            errorMessage = String(localized: "Microphone access is restricted by macOS and cannot be requested by Bardo.")
        case .error(let message):
            errorMessage = message
        }
    }
}
