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
        case paused
        case changingSelection
        case finalizing
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var includesMicrophone = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryIssues: [RecordingStoreIssue] = []

    var isRecording: Bool { phase == .recording || phase == .paused || phase == .changingSelection }
    var isPaused: Bool { phase == .paused }

    var isBusy: Bool {
        switch phase {
        case .requestingMicrophonePermission, .selectingContent, .preparing, .recording, .paused, .changingSelection, .finalizing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var requiresTerminationFinalization: Bool {
        phase == .recording || phase == .paused || phase == .changingSelection || phase == .finalizing
    }

    static var activeForApplicationTermination: SystemAudioRecordingController? {
        activeController
    }

    private struct Session {
        let prepared: SystemAudioCaptureStagingStore.PreparedCapture
        let startedAt: Date
        let includeMicrophone: Bool
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

    func start(includeMicrophone: Bool) async {
        errorMessage = nil
        guard !isBusy else {
            errorMessage = "A system-audio recording is already active or changing state."
            return
        }
        guard RecordingCaptureLease.acquire(ownerID: captureLeaseID) else {
            errorMessage = "Another Bardo recording is already active."
            return
        }

        Self.activeController = self
        requestedModeIncludesMicrophone = includeMicrophone
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

    func pause() async {
        guard phase == .recording else { return }
        do {
            refreshElapsedTime()
            try await backend.pause()
            stopProgressUpdates()
            phase = .paused
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume() async {
        guard phase == .paused else { return }
        do {
            try await backend.resume()
            phase = .recording
            errorMessage = nil
            startProgressUpdates()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        if phase == .recording || phase == .paused || phase == .changingSelection {
            _ = await stop()
        }
        while phase == .finalizing {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func refreshElapsedTime() {
        guard phase == .recording || phase == .changingSelection else { return }
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
            includesMicrophone = false
        }
    }

    private func handlePickerEvent(_ event: SystemContentSelectionEvent) async {
        switch event {
        case .selected(let selection, let isUpdate):
            if phase == .changingSelection || (isUpdate && phase == .recording) {
                phase = .changingSelection
                do {
                    try await backend.update(selection: selection)
                    phase = .recording
                } catch {
                    errorMessage = "Bardo kept the current capture because the new selection could not be applied: \(error.localizedDescription)"
                    phase = .recording
                }
                return
            }

            guard phase == .selectingContent else { return }
            await beginCapture(selection: selection)

        case .cancelled(let isUpdate):
            if phase == .changingSelection || (isUpdate && phase == .recording) {
                phase = .recording
                return
            }
            guard phase == .selectingContent else { return }
            finishWithoutCapture(message: nil)

        case .failed(let message):
            if phase == .changingSelection || phase == .recording {
                errorMessage = "The system sharing picker could not update the selection: \(message)"
                phase = .recording
            } else if phase == .selectingContent {
                finishWithoutCapture(message: "The system sharing picker could not start: \(message)")
            }
        }
    }

    private func beginCapture(selection: SystemContentSelection) async {
        phase = .preparing
        let recordingID = UUID()
        let systemAssetID = UUID()
        let microphoneAssetID = requestedModeIncludesMicrophone ? UUID() : nil
        let mixAssetID = requestedModeIncludesMicrophone ? UUID() : nil

        do {
            let stagingStore = try resolveStagingStore()
            let prepared = try await stagingStore.prepareCapture(
                recordingID: recordingID,
                systemAssetID: systemAssetID,
                microphoneAssetID: microphoneAssetID,
                mixAssetID: mixAssetID
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
                startedAt: Date(),
                includeMicrophone: requestedModeIncludesMicrophone
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
        guard isRecording, session != nil, !backendInterruptionInProgress else { return }
        backendInterruptionInProgress = true
        phase = .finalizing
        stopProgressUpdates()

        let message: String
        switch event {
        case .interrupted(let detail):
            message = detail
        }

        let result = await backend.stop()
        _ = await publishCapture(result: result, interruptionMessage: message)
        backendInterruptionInProgress = false
    }

    private func publishCapture(
        result: SystemAudioCaptureResult,
        interruptionMessage: String?
    ) async -> Recording? {
        guard let session else { return nil }
        let prepared = session.prepared

        do {
            let store = try resolveStore()
            let stagingStore = try resolveStagingStore()
            await stagingStore.finishActiveCapture(recordingID: prepared.recordingID)

            var sourceAssets: [AudioAsset] = []
            var sourceFiles: [AudioAsset.ID: URL] = [:]
            var warnings: [String] = []

            if let timing = result.systemTrack {
                do {
                    let metadata = try metadataReader.read(from: prepared.systemURL)
                    try CaptureDurationIntegrity.validate(
                        expected: max(0, timing.lastPresentationTime - timing.firstPresentationTime),
                        finalized: metadata.duration
                    )
                    let asset = AudioAsset(
                        id: prepared.systemAssetID,
                        originalFileName: "System Audio.m4a",
                        fileExtension: "m4a",
                        metadata: metadata,
                        role: .systemOriginal,
                        timelineOffset: 0
                    )
                    sourceAssets.append(asset)
                    sourceFiles[asset.id] = prepared.systemURL
                } catch {
                    warnings.append("System audio could not be validated: \(error.localizedDescription)")
                }
            } else if let error = result.systemError {
                warnings.append(error)
            }

            if session.includeMicrophone, let microphoneURL = prepared.microphoneURL {
                if let timing = result.microphoneTrack {
                    do {
                        let metadata = try metadataReader.read(from: microphoneURL)
                        try CaptureDurationIntegrity.validate(
                            expected: max(0, timing.lastPresentationTime - timing.firstPresentationTime),
                            finalized: metadata.duration
                        )
                        let asset = AudioAsset(
                            id: prepared.microphoneAssetID ?? UUID(),
                            originalFileName: "Microphone.m4a",
                            fileExtension: "m4a",
                            metadata: metadata,
                            role: .microphoneOriginal,
                            timelineOffset: 0
                        )
                        sourceAssets.append(asset)
                        sourceFiles[asset.id] = microphoneURL
                    } catch {
                        warnings.append("Microphone audio could not be validated: \(error.localizedDescription)")
                    }
                } else if let error = result.microphoneError {
                    warnings.append(error)
                }
            }

            guard !sourceAssets.isEmpty else {
                throw SystemAudioCaptureError.noAudioSamples("system or microphone")
            }

            let firstPTSValues = [result.systemTrack?.firstPresentationTime, result.microphoneTrack?.firstPresentationTime]
                .compactMap { $0 }
                .filter(\.isFinite)
            let origin = firstPTSValues.min() ?? 0
            sourceAssets = sourceAssets.map { asset in
                let firstPTS: TimeInterval?
                switch asset.role {
                case .systemOriginal:
                    firstPTS = result.systemTrack?.firstPresentationTime
                case .microphoneOriginal:
                    firstPTS = result.microphoneTrack?.firstPresentationTime
                default:
                    firstPTS = nil
                }
                return AudioAsset(
                    id: asset.id,
                    originalFileName: asset.originalFileName,
                    fileExtension: asset.fileExtension,
                    metadata: asset.metadata,
                    role: asset.role,
                    timelineOffset: max(0, (firstPTS ?? origin) - origin),
                    derivedFromAssetIDs: []
                )
            }

            var allAssets = sourceAssets
            var allFiles = sourceFiles
            let systemAsset = sourceAssets.first(where: { $0.role == .systemOriginal })
            let microphoneAsset = sourceAssets.first(where: { $0.role == .microphoneOriginal })

            if let systemAsset,
               let microphoneAsset,
               let microphoneURL = prepared.microphoneURL,
               let mixURL = prepared.mixURL,
               let mixAssetID = prepared.mixAssetID {
                do {
                    let mixMetadata = try await mixer.makeMix(
                        systemURL: prepared.systemURL,
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
                    warnings.append("The original sources were preserved, but the derived conversation mix could not be generated: \(error.localizedDescription)")
                }
            }

            if let stopError = result.streamStopError {
                warnings.append("ScreenCaptureKit reported a stop error after capture: \(stopError)")
            }
            if let interruptionMessage {
                warnings.append("Capture ended unexpectedly: \(interruptionMessage)")
            }

            let sources = Set(sourceAssets.compactMap { asset -> AudioSource? in
                switch asset.role {
                case .systemOriginal: return .systemAudio
                case .microphoneOriginal: return .microphone
                default: return nil
                }
            })
            let duration = allAssets.map { $0.timelineOffset + $0.metadata.duration }.max()
            let title = sources == [.systemAudio, .microphone]
                ? "System + Microphone Recording"
                : (sources == [.systemAudio] ? "System Audio Recording" : "Microphone Recording")
            let recording = Recording(
                id: prepared.recordingID,
                title: title,
                createdAt: session.startedAt,
                duration: duration,
                sources: sources,
                processingState: .pending,
                audioAssets: allAssets
            )

            try await store.importRecording(recording, audioFiles: allFiles)

            let capturedBothRequestedSources = !session.includeMicrophone || (systemAsset != nil && microphoneAsset != nil)
            if capturedBothRequestedSources {
                try? await stagingStore.discardCapture(recordingID: prepared.recordingID)
            }

            self.session = nil
            phase = .idle
            elapsedTime = 0
            includesMicrophone = false
            picker.deactivate()
            releaseCaptureLease()
            await refreshRecoveryIssues()

            if !warnings.isEmpty {
                errorMessage = warnings.joined(separator: "\n")
            } else {
                errorMessage = nil
            }
            return recording
        } catch {
            if let stagingStore {
                await stagingStore.finishActiveCapture(recordingID: prepared.recordingID)
            }
            self.session = nil
            phase = .failed
            errorMessage = "The capture ended, but Bardo could not safely publish it: \(error.localizedDescription)"
            elapsedTime = max(elapsedTime, backend.currentTime)
            picker.deactivate()
            releaseCaptureLease()
            await refreshRecoveryIssues()
            return nil
        }
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
                guard !Task.isCancelled, let self, self.phase == .recording || self.phase == .changingSelection else { return }
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
        errorMessage = message
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
            return "Microphone permission is still awaiting a response."
        case .authorized:
            return ""
        case .denied:
            return "Microphone access is denied. Enable Bardo in System Settings → Privacy & Security → Microphone before recording both sources."
        case .restricted:
            return "Microphone access is restricted by macOS, so dual-source recording cannot start."
        case .error(let message):
            return message
        }
    }
}
