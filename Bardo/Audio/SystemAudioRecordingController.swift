import AppKit
import Combine
import Foundation

@MainActor
final class SystemAudioRecordingController: ObservableObject {
    enum Phase: String, Equatable, Sendable {
        case idle
        case requestingMicrophonePermission
        case selectingContent
        case preparing
        case recording
        case changingSelection
        case finalizing
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var includesMicrophone = false
    @Published private(set) var errorMessage: String?
    /// A non-fatal problem during an active capture, such as one track stopping.
    @Published private(set) var captureWarning: String?
    @Published private(set) var recoveryIssues: [RecordingStoreIssue] = []
    @Published private(set) var isRecovering = false

    /// Called on the main actor for every recording this controller adds to the
    /// Library: normal stops, interruptions that kept audio, and recoveries.
    var onRecordingPublished: ((Recording) -> Void)?

    var isRecording: Bool { phase == .recording || phase == .changingSelection }

    var isBusy: Bool {
        switch phase {
        case .requestingMicrophonePermission, .selectingContent, .preparing, .recording, .changingSelection, .finalizing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var requiresTerminationFinalization: Bool {
        phase == .recording || phase == .changingSelection || phase == .finalizing
    }

    static var activeForApplicationTermination: SystemAudioRecordingController? {
        activeController
    }

    private struct Session {
        let prepared: SystemAudioCaptureStagingStore.PreparedCapture
        let startedAt: Date
        let includeMicrophone: Bool
        let title: String?
    }

    /// One source file to publish, with its first-sample time when it is known.
    private struct StagedTrack {
        let role: AudioAssetRole
        let assetID: UUID
        let url: URL
        let firstPresentationTime: TimeInterval?
    }

    private static weak var activeController: SystemAudioRecordingController?

    private var store: RecordingStore?
    private var stagingStore: SystemAudioCaptureStagingStore?
    private let picker: any SystemContentSelecting
    private let backend: any SystemAudioCapturing
    private let microphonePermission: any MicrophonePermissionAuthorizing
    private let metadataReader: AudioMetadataReader
    private let mixer: any ConversationMixing
    private let captureLeaseID = UUID()
    private var session: Session?
    private var progressTask: Task<Void, Never>?
    private var requestedModeIncludesMicrophone = false
    private var requestedTitle: String?
    private var backendInterruptionInProgress = false

    init(
        store: RecordingStore? = nil,
        stagingStore: SystemAudioCaptureStagingStore? = nil,
        picker: any SystemContentSelecting = ScreenCapturePickerCoordinator(),
        backend: any SystemAudioCapturing = ScreenCaptureKitAudioBackend(),
        microphonePermission: any MicrophonePermissionAuthorizing = SystemMicrophonePermissionAuthorizer(),
        metadataReader: AudioMetadataReader = AudioMetadataReader(),
        mixer: any ConversationMixing = AVFoundationConversationMixer()
    ) {
        self.store = store
        self.stagingStore = stagingStore
        self.picker = picker
        self.backend = backend
        self.microphonePermission = microphonePermission
        self.metadataReader = metadataReader
        self.mixer = mixer

        picker.eventHandler = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                await self.handlePickerEvent(event)
            }
        }
        backend.eventHandler = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                await self.handleBackendEvent(event)
            }
        }
    }

    func start(includeMicrophone: Bool, title: String? = nil) async {
        errorMessage = nil
        captureWarning = nil
        guard !isBusy, !isRecovering else {
            errorMessage = String(localized: "A system-audio recording is already active or changing state.")
            return
        }
        guard RecordingCaptureLease.acquire(ownerID: captureLeaseID) else {
            errorMessage = String(localized: "Another Bardo recording is already active.")
            return
        }

        Self.activeController = self
        requestedModeIncludesMicrophone = includeMicrophone
        requestedTitle = title
        includesMicrophone = includeMicrophone

        if includeMicrophone {
            let permission = microphonePermission.currentStatus()
            switch permission {
            case .authorized:
                break
            case .notDetermined:
                phase = .requestingMicrophonePermission
                let requested = await microphonePermission.requestAccess()
                guard requested == .authorized else {
                    finishWithoutCapture(message: microphonePermissionMessage(requested))
                    return
                }
            case .denied, .restricted, .error:
                finishWithoutCapture(message: microphonePermissionMessage(permission))
                return
            }
        }

        do {
            _ = try resolveStore()
            _ = try resolveStagingStore()
            phase = .selectingContent
            picker.present()
        } catch {
            finishWithoutCapture(message: error.localizedDescription)
        }
    }

    /// Abandons a capture whose content has not been chosen yet.
    func cancelContentSelection() {
        guard phase == .selectingContent else { return }
        finishWithoutCapture(message: nil)
    }

    func changeSelection() {
        guard phase == .recording else { return }
        phase = .changingSelection
        picker.present()
    }

    @discardableResult
    func stop() async -> Recording? {
        guard isRecording, session != nil else { return nil }
        phase = .finalizing
        stopProgressUpdates()
        let result = await backend.stop()
        return await publishCapture(result: result, interruptionMessage: nil)
    }

    func prepareForApplicationTermination() async {
        if phase == .recording || phase == .changingSelection {
            _ = await stop()
        }
        while phase == .finalizing {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func refreshElapsedTime() {
        guard isRecording else { return }
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

    /// Publishes the readable audio of an interrupted capture into the Library. Sources
    /// are aligned at their start because the interruption lost their exact timing.
    @discardableResult
    func recoverRecoveryIssue(_ issue: RecordingStoreIssue) async -> Recording? {
        guard let recordingID = issue.recordingID, !isBusy, !isRecovering else { return nil }
        isRecovering = true
        defer { isRecovering = false }

        do {
            let stagingStore = try resolveStagingStore()
            guard let contents = await stagingStore.contents(recordingID: recordingID) else {
                await refreshRecoveryIssues()
                return nil
            }

            if (try? await resolveStore().read(id: recordingID)) != nil {
                try? await stagingStore.discardCapture(recordingID: recordingID)
                await refreshRecoveryIssues()
                errorMessage = CapturePublicationError.alreadyInLibrary.localizedDescription
                return nil
            }

            let readable = contents.audioFiles.filter { (try? metadataReader.read(from: $0)) != nil }
            let manifest = contents.manifest
            var tracks: [StagedTrack] = []
            for url in readable {
                let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                if let manifest {
                    // Only original sources are recovered; a stale mix is derived again.
                    if let fileID, fileID == manifest.systemAssetID {
                        tracks.append(StagedTrack(role: .systemOriginal, assetID: fileID, url: url, firstPresentationTime: nil))
                    } else if let fileID, fileID == manifest.microphoneAssetID {
                        tracks.append(StagedTrack(role: .microphoneOriginal, assetID: fileID, url: url, firstPresentationTime: nil))
                    }
                } else if tracks.isEmpty {
                    // Without bookkeeping the source is unknown; keep the system role.
                    tracks.append(StagedTrack(role: .systemOriginal, assetID: fileID ?? UUID(), url: url, firstPresentationTime: nil))
                }
            }
            guard !tracks.isEmpty else { throw CapturePublicationError.noAudioCaptured }
            tracks.sort { $0.role == .systemOriginal && $1.role != .systemOriginal }

            let mixAssetID = manifest?.mixAssetID ?? UUID()
            let (recording, _) = try await assembleAndPublish(
                recordingID: recordingID,
                tracks: tracks,
                mixAssetID: mixAssetID,
                mixURL: contents.directoryURL.appendingPathComponent("\(mixAssetID.uuidString)-recovered.m4a"),
                title: manifest?.title,
                startedAt: contents.startedAt
            )
            try? await stagingStore.discardCapture(recordingID: recordingID)
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
        guard let root = try? SystemAudioCaptureStagingStore.liveRootURL() else { return false }
        return NSWorkspace.shared.open(root)
    }

    func clearError() {
        errorMessage = nil
        if phase == .failed {
            phase = .idle
            elapsedTime = 0
            includesMicrophone = false
        }
    }

    private func handlePickerEvent(_ event: SystemContentSelectionEvent) async {
        switch event {
        case .selected(let selection, let isUpdate):
            if phase == .changingSelection || (isUpdate && isRecording) {
                phase = .changingSelection
                do {
                    try await backend.update(selection: selection)
                    // Stop may have begun finalizing while the update was in flight.
                    if phase == .changingSelection { phase = .recording }
                } catch {
                    guard phase == .changingSelection else { return }
                    captureWarning = String(localized: "Bardo kept the current capture because the new selection could not be applied: \(error.localizedDescription)")
                    phase = .recording
                }
                return
            }

            guard phase == .selectingContent else { return }
            await beginCapture(selection: selection)

        case .cancelled(let isUpdate):
            if phase == .changingSelection {
                phase = .recording
                return
            }
            if isUpdate { return }
            guard phase == .selectingContent else { return }
            finishWithoutCapture(message: nil)

        case .failed(let message):
            if phase == .changingSelection {
                captureWarning = String(localized: "The system sharing picker could not update the selection: \(message)")
                phase = .recording
            } else if isRecording {
                captureWarning = String(localized: "The system sharing picker could not update the selection: \(message)")
            } else if phase == .selectingContent {
                finishWithoutCapture(message: String(localized: "The system sharing picker could not start: \(message)"))
            }
        }
    }

    private func beginCapture(selection: SystemContentSelection) async {
        phase = .preparing
        let recordingID = UUID()
        let systemAssetID = UUID()
        let microphoneAssetID = requestedModeIncludesMicrophone ? UUID() : nil
        let mixAssetID = requestedModeIncludesMicrophone ? UUID() : nil
        let startedAt = Date()

        do {
            let stagingStore = try resolveStagingStore()
            let prepared = try await stagingStore.prepareCapture(
                recordingID: recordingID,
                systemAssetID: systemAssetID,
                microphoneAssetID: microphoneAssetID,
                mixAssetID: mixAssetID,
                title: requestedTitle,
                startedAt: startedAt
            )

            do {
                try await backend.start(
                    selection: selection,
                    includeMicrophone: requestedModeIncludesMicrophone,
                    systemURL: prepared.systemURL,
                    microphoneURL: prepared.microphoneURL
                )
            } catch {
                try? await stagingStore.discardCapture(recordingID: recordingID)
                throw error
            }

            session = Session(
                prepared: prepared,
                startedAt: startedAt,
                includeMicrophone: requestedModeIncludesMicrophone,
                title: requestedTitle
            )
            elapsedTime = max(0, backend.currentTime)
            phase = .recording
            startProgressUpdates()
        } catch {
            session = nil
            phase = .failed
            errorMessage = error.localizedDescription
            picker.deactivate()
            releaseCaptureLease()
            await refreshRecoveryIssues()
        }
    }

    private func handleBackendEvent(_ event: SystemAudioCaptureBackendEvent) async {
        switch event {
        case .trackFailed(let detail):
            guard isRecording else { return }
            captureWarning = String(localized: "\(detail) The other source is still recording.")

        case .interrupted(let detail):
            guard isRecording, session != nil, !backendInterruptionInProgress else { return }
            backendInterruptionInProgress = true
            phase = .finalizing
            stopProgressUpdates()

            let result = await backend.stop()
            _ = await publishCapture(result: result, interruptionMessage: detail)
            backendInterruptionInProgress = false
        }
    }

    private func publishCapture(
        result: SystemAudioCaptureResult,
        interruptionMessage: String?
    ) async -> Recording? {
        guard let session else { return nil }
        let prepared = session.prepared
        let stagingStore = try? resolveStagingStore()
        await stagingStore?.finishActiveCapture(recordingID: prepared.recordingID)

        var warnings: [String] = []
        var tracks: [StagedTrack] = []

        if let timing = result.systemTrack {
            tracks.append(StagedTrack(
                role: .systemOriginal,
                assetID: prepared.systemAssetID,
                url: prepared.systemURL,
                firstPresentationTime: timing.firstPresentationTime
            ))
            if let warning = timing.warning { warnings.append(warning) }
        } else if let error = result.systemError {
            warnings.append(error)
        }

        if session.includeMicrophone, let microphoneURL = prepared.microphoneURL {
            if let timing = result.microphoneTrack {
                tracks.append(StagedTrack(
                    role: .microphoneOriginal,
                    assetID: prepared.microphoneAssetID ?? UUID(),
                    url: microphoneURL,
                    firstPresentationTime: timing.firstPresentationTime
                ))
                if let warning = timing.warning { warnings.append(warning) }
            } else if let error = result.microphoneError {
                warnings.append(error)
            }
        }

        if let stopError = result.streamStopError {
            warnings.append(String(localized: "ScreenCaptureKit reported a stop error after capture: \(stopError)"))
        }
        if let interruptionMessage {
            warnings.append(String(localized: "Capture ended unexpectedly: \(interruptionMessage)"))
        }

        do {
            let (recording, assemblyWarnings) = try await assembleAndPublish(
                recordingID: prepared.recordingID,
                tracks: tracks,
                mixAssetID: prepared.mixAssetID,
                mixURL: prepared.mixURL,
                title: session.title,
                startedAt: session.startedAt
            )
            warnings.insert(contentsOf: assemblyWarnings, at: 0)

            let publishedRoles = Set(recording.audioAssets.map(\.role))
            let capturedEveryRequestedSource = publishedRoles.contains(.systemOriginal)
                && (!session.includeMicrophone || publishedRoles.contains(.microphoneOriginal))
            if capturedEveryRequestedSource {
                try? await stagingStore?.discardCapture(recordingID: prepared.recordingID)
            }

            self.session = nil
            phase = .idle
            elapsedTime = 0
            includesMicrophone = false
            captureWarning = nil
            picker.deactivate()
            releaseCaptureLease()
            await refreshRecoveryIssues()

            errorMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            onRecordingPublished?(recording)
            return recording
        } catch {
            self.session = nil
            phase = .failed
            let context = warnings.isEmpty ? "" : "\n" + warnings.joined(separator: "\n")
            errorMessage = String(localized: "The capture ended, but Bardo could not safely publish it: \(error.localizedDescription) It was kept for recovery.\(context)")
            elapsedTime = max(elapsedTime, backend.currentTime)
            captureWarning = nil
            picker.deactivate()
            releaseCaptureLease()
            await refreshRecoveryIssues()
            return nil
        }
    }

    /// Validates staged sources, aligns them on one timeline, derives the conversation
    /// mix when both sources exist, and moves everything into the Library.
    private func assembleAndPublish(
        recordingID: UUID,
        tracks: [StagedTrack],
        mixAssetID: UUID?,
        mixURL: URL?,
        title: String?,
        startedAt: Date
    ) async throws -> (Recording, [String]) {
        let store = try resolveStore()
        var warnings: [String] = []
        var validated: [(track: StagedTrack, metadata: AudioMetadata)] = []

        for track in tracks {
            do {
                validated.append((track, try metadataReader.read(from: track.url)))
            } catch {
                let source = track.role == .systemOriginal ? String(localized: "the system audio") : String(localized: "the microphone audio")
                warnings.append(String(localized: "Bardo could not validate \(source): \(error.localizedDescription)"))
            }
        }
        guard !validated.isEmpty else {
            throw SystemAudioCaptureError.noAudioSamples("system or microphone")
        }

        // Normalize first-sample PTS values onto a durable recording-relative timeline.
        // Absolute host-clock values never enter Domain or persistence.
        let origin = validated.compactMap(\.track.firstPresentationTime).filter(\.isFinite).min() ?? 0
        let sourceAssets = validated.map { item in
            AudioAsset(
                id: item.track.assetID,
                originalFileName: item.track.role == .systemOriginal ? "System Audio.m4a" : "Microphone.m4a",
                fileExtension: item.track.url.pathExtension,
                metadata: item.metadata,
                role: item.track.role,
                timelineOffset: max(0, (item.track.firstPresentationTime ?? origin) - origin)
            )
        }

        var allAssets = sourceAssets
        var allFiles = Dictionary(uniqueKeysWithValues: zip(sourceAssets.map(\.id), validated.map(\.track.url)))
        let systemAsset = sourceAssets.first { $0.role == .systemOriginal }
        let microphoneAsset = sourceAssets.first { $0.role == .microphoneOriginal }

        if let systemAsset, let microphoneAsset,
           let systemURL = allFiles[systemAsset.id],
           let microphoneURL = allFiles[microphoneAsset.id],
           let mixURL, let mixAssetID {
            do {
                let mixMetadata = try await mixer.makeMix(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    systemOffset: systemAsset.timelineOffset,
                    microphoneOffset: microphoneAsset.timelineOffset,
                    outputURL: mixURL
                )
                let mix = AudioAsset(
                    id: mixAssetID,
                    originalFileName: "Conversation Mix.m4a",
                    fileExtension: "m4a",
                    metadata: mixMetadata,
                    role: .conversationMix,
                    timelineOffset: 0,
                    derivedFromAssetIDs: [systemAsset.id, microphoneAsset.id]
                )
                allAssets.append(mix)
                allFiles[mix.id] = mixURL
            } catch {
                try? FileManager.default.removeItem(at: mixURL)
                warnings.append(String(localized: "The original sources were preserved, but the derived conversation mix could not be generated: \(error.localizedDescription)"))
            }
        }

        let sources = Set(sourceAssets.compactMap { asset -> AudioSource? in
            switch asset.role {
            case .systemOriginal: return .systemAudio
            case .microphoneOriginal: return .microphone
            default: return nil
            }
        })
        let duration = allAssets.map { $0.timelineOffset + $0.metadata.duration }.max()
        let defaultTitle = sources == [.systemAudio, .microphone]
            ? "System + Microphone Recording"
            : (sources == [.systemAudio] ? "System Audio Recording" : "Microphone Recording")
        let recording = Recording(
            id: recordingID,
            title: title ?? defaultTitle,
            createdAt: startedAt,
            duration: duration,
            sources: sources,
            processingState: .pending,
            audioAssets: allAssets
        )

        try await store.importRecording(recording, audioFiles: allFiles, transferringOwnership: true)
        return (recording, warnings)
    }

    private func resolveStore() throws -> RecordingStore {
        if let store { return store }
        let liveStore = try RecordingStore.live()
        store = liveStore
        return liveStore
    }

    private func resolveStagingStore() throws -> SystemAudioCaptureStagingStore {
        if let stagingStore { return stagingStore }
        let liveStore = try SystemAudioCaptureStagingStore.live()
        stagingStore = liveStore
        return liveStore
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                self.refreshElapsedTime()
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func finishWithoutCapture(message: String?) {
        session = nil
        phase = .idle
        elapsedTime = 0
        includesMicrophone = false
        captureWarning = nil
        errorMessage = message
        requestedTitle = nil
        picker.deactivate()
        releaseCaptureLease()
    }

    private func releaseCaptureLease() {
        RecordingCaptureLease.release(ownerID: captureLeaseID)
        if Self.activeController === self {
            Self.activeController = nil
        }
    }

    private func microphonePermissionMessage(_ state: MicrophonePermissionState) -> String {
        switch state {
        case .notDetermined:
            return String(localized: "Microphone permission is still awaiting a response.")
        case .authorized:
            return ""
        case .denied:
            return String(localized: "Microphone access is denied. Enable Bardo in System Settings → Privacy & Security → Microphone before recording both sources.")
        case .restricted:
            return String(localized: "Microphone access is restricted by macOS, so dual-source recording cannot start.")
        case .error(let message):
            return message
        }
    }
}
