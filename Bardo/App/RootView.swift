import SwiftUI

struct RootView: View {
    private enum CaptureMode: String {
        case microphone
        case systemAudio
        case systemAudioAndMicrophone
    }

    private let warmTranscriptionForRecording: @MainActor () -> Void

    @StateObject private var library = LibraryViewModel()
    @StateObject private var microphone = MicrophoneRecordingController()
    @StateObject private var systemAudio = SystemAudioRecordingController()
    @AppStorage("Bardo.LastCaptureMode") private var lastCaptureModeRaw = CaptureMode.microphone.rawValue
    @State private var isRecoveryNoticeDismissed = false

    init(warmTranscriptionForRecording: @escaping @MainActor () -> Void = {}) {
        self.warmTranscriptionForRecording = warmTranscriptionForRecording
    }

    var body: some View {
        rootContent
            .task {
                microphone.refreshPermissionState()
                await microphone.refreshRecoveryIssues()
                await systemAudio.refreshRecoveryIssues()
            }
            .alert(
                microphoneAlertTitle,
                isPresented: Binding(
                    get: { microphone.errorMessage != nil },
                    set: { if !$0 { microphone.clearError() } }
                )
            ) {
                if microphone.permissionState == .denied {
                    Button("Open System Settings") {
                        _ = microphone.openMicrophoneSystemSettings()
                    }
                }
                Button("OK", role: .cancel) {
                    microphone.clearError()
                }
            } message: {
                Text(microphone.errorMessage ?? "Microphone recording could not continue.")
            }
            .alert(
                "System Audio Recording",
                isPresented: Binding(
                    get: { systemAudio.errorMessage != nil },
                    set: { if !$0 { systemAudio.clearError() } }
                )
            ) {
                Button("OK", role: .cancel) {
                    systemAudio.clearError()
                }
            } message: {
                Text(systemAudio.errorMessage ?? "System audio recording could not continue.")
            }
            .onDisappear {
                Task {
                    if microphone.requiresTerminationFinalization {
                        await microphone.prepareForApplicationTermination()
                    }
                    if systemAudio.requiresTerminationFinalization {
                        await systemAudio.prepareForApplicationTermination()
                    }
                    await library.reload()
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if MacOSUICompatibility.usesNativeToolbar {
            libraryView
                .toolbar {
                    captureToolbar
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    captureStatusBar
                }
        } else {
            libraryView
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        captureCompatibilityBar
                        captureStatusBar
                    }
                }
        }
    }

    private var libraryView: some View {
        LibraryView(
            model: library,
            onNewRecording: {
                Task { await startLastRecording() }
            }
        )
    }

    @ToolbarContentBuilder
    private var captureToolbar: some ToolbarContent {
        if microphone.isRecording {
            ToolbarItem(id: "bardo.capture.status", placement: .automatic) {
                activeRecordingStatus(
                    title: microphone.isPaused ? "Paused" : "Recording",
                    duration: microphone.elapsedTime,
                    help: microphone.inputDisplayName ?? "Default microphone"
                )
            }

            ToolbarItem(id: "bardo.capture.pause-resume", placement: .automatic) {
                Button {
                    if microphone.isPaused {
                        microphone.resume()
                    } else {
                        microphone.pause()
                    }
                } label: {
                    Label(
                        microphone.isPaused ? "Resume Recording" : "Pause Recording",
                        systemImage: microphone.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(microphone.isPaused ? "Resume microphone recording" : "Pause microphone recording")
            }

            ToolbarItem(id: "bardo.capture.stop", placement: .automatic) {
                Button {
                    Task { await stopMicrophoneRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .help("Stop microphone recording")
            }
        } else if systemAudio.isRecording {
            ToolbarItem(id: "bardo.capture.status", placement: .automatic) {
                activeRecordingStatus(
                    title: systemAudio.isPaused ? "Paused" : "Recording",
                    duration: systemAudio.elapsedTime,
                    help: systemAudio.includesMicrophone ? "System Audio + Microphone" : "System Audio"
                )
            }

            ToolbarItem(id: "bardo.capture.pause-resume", placement: .automatic) {
                Button {
                    Task {
                        if systemAudio.isPaused {
                            await systemAudio.resume()
                        } else {
                            await systemAudio.pause()
                        }
                    }
                } label: {
                    Label(
                        systemAudio.isPaused ? "Resume Recording" : "Pause Recording",
                        systemImage: systemAudio.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .disabled(systemAudio.phase == .changingSelection)
                .help(systemAudio.isPaused ? "Resume system audio recording" : "Pause system audio recording")
            }

            if !systemAudio.isPaused && systemAudio.phase != .changingSelection {
                ToolbarItem(id: "bardo.capture.change-source", placement: .automatic) {
                    Button {
                        systemAudio.changeSelection()
                    } label: {
                        Label("Change Source…", systemImage: "rectangle.on.rectangle")
                    }
                    .help("Choose different macOS content without restarting the recording")
                }
            }

            ToolbarItem(id: "bardo.capture.stop", placement: .automatic) {
                Button {
                    Task { await stopSystemRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .help("Stop system audio recording")
            }
        } else {
            ToolbarItem(id: "bardo.capture.new", placement: .automatic) {
                newRecordingMenu
            }
        }
    }

    @ViewBuilder
    private var captureCompatibilityBar: some View {
        HStack(spacing: 10) {
            if microphone.isRecording {
                activeRecordingStatus(
                    title: microphone.isPaused ? "Paused" : "Recording",
                    duration: microphone.elapsedTime,
                    help: microphone.inputDisplayName ?? "Default microphone"
                )

                Spacer(minLength: 12)

                Button {
                    if microphone.isPaused {
                        microphone.resume()
                    } else {
                        microphone.pause()
                    }
                } label: {
                    Label(
                        microphone.isPaused ? "Resume Recording" : "Pause Recording",
                        systemImage: microphone.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .labelStyle(.iconOnly)
                .help(microphone.isPaused ? "Resume microphone recording" : "Pause microphone recording")

                Button {
                    Task { await stopMicrophoneRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .labelStyle(.iconOnly)
                .help("Stop microphone recording")
            } else if systemAudio.isRecording {
                activeRecordingStatus(
                    title: systemAudio.isPaused ? "Paused" : "Recording",
                    duration: systemAudio.elapsedTime,
                    help: systemAudio.includesMicrophone ? "System Audio + Microphone" : "System Audio"
                )

                Spacer(minLength: 12)

                Button {
                    Task {
                        if systemAudio.isPaused {
                            await systemAudio.resume()
                        } else {
                            await systemAudio.pause()
                        }
                    }
                } label: {
                    Label(
                        systemAudio.isPaused ? "Resume Recording" : "Pause Recording",
                        systemImage: systemAudio.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .labelStyle(.iconOnly)
                .disabled(systemAudio.phase == .changingSelection)
                .help(systemAudio.isPaused ? "Resume system audio recording" : "Pause system audio recording")

                if !systemAudio.isPaused && systemAudio.phase != .changingSelection {
                    Button {
                        systemAudio.changeSelection()
                    } label: {
                        Label("Change Source…", systemImage: "rectangle.on.rectangle")
                    }
                    .labelStyle(.iconOnly)
                    .help("Choose different macOS content without restarting the recording")
                }

                Button {
                    Task { await stopSystemRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .labelStyle(.iconOnly)
                .help("Stop system audio recording")
            } else {
                Spacer(minLength: 0)
                newRecordingMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var newRecordingMenu: some View {
        Menu {
            Button {
                Task { await startMicrophoneRecording() }
            } label: {
                Label("Microphone", systemImage: "mic")
            }

            Divider()

            Button {
                Task { await startSystemRecording(includeMicrophone: false) }
            } label: {
                Label("System Audio", systemImage: "macbook.and.iphone")
            }

            Button {
                Task { await startSystemRecording(includeMicrophone: true) }
            } label: {
                Label("System Audio + Microphone", systemImage: "person.wave.2")
            }
        } label: {
            Label("New Recording", systemImage: "record.circle")
        }
        .keyboardShortcut("n", modifiers: .command)
        .help("Start a new recording")
        .disabled(microphone.isBusy || systemAudio.isBusy)
    }

    private func activeRecordingStatus(
        title: String,
        duration: TimeInterval,
        help: String
    ) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                Text(LibraryFormatting.duration(duration))
                    .monospacedDigit()
            }
            .font(.callout.weight(.medium))
        } icon: {
            Image(systemName: title == "Paused" ? "pause.circle.fill" : "record.circle.fill")
        }
        .help(help)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var captureStatusBar: some View {
        if microphone.phase != .idle && microphone.phase != .failed {
            microphoneTransitionStatus
                .padding(.horizontal, 18)
                .padding(.top, 8)
        } else if systemAudio.phase != .idle && systemAudio.phase != .failed {
            systemAudioTransitionStatus
                .padding(.horizontal, 18)
                .padding(.top, 8)
        } else {
            recoveryStatusBar
        }
    }

    @ViewBuilder
    private var microphoneTransitionStatus: some View {
        switch microphone.phase {
        case .requestingPermission:
            transitionPill(
                title: "Waiting for Microphone Permission",
                detail: "Respond to the macOS permission prompt."
            )
        case .preparing:
            transitionPill(
                title: "Preparing Recording",
                detail: "Getting the microphone ready."
            )
        case .finalizing:
            transitionPill(
                title: "Finishing Recording",
                detail: "Making sure the full audio is safely stored."
            )
        case .recording, .paused, .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var systemAudioTransitionStatus: some View {
        switch systemAudio.phase {
        case .requestingMicrophonePermission:
            transitionPill(
                title: "Waiting for Microphone Permission",
                detail: "Microphone access is only needed for the combined recording mode."
            )
        case .selectingContent:
            transitionPill(
                title: "Choose What to Record",
                detail: "Use the macOS picker to choose a display, app, or window."
            )
        case .preparing:
            transitionPill(
                title: "Preparing Recording",
                detail: systemAudio.includesMicrophone
                    ? "Getting system audio and the microphone ready."
                    : "Getting system audio ready."
            )
        case .changingSelection:
            transitionPill(
                title: "Choose a New Source",
                detail: "Recording continues while the macOS picker is open."
            )
        case .finalizing:
            transitionPill(
                title: "Finishing Recording",
                detail: "Making sure the full audio is safely stored."
            )
        case .recording, .paused, .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var recoveryStatusBar: some View {
        let total = microphone.recoveryIssues.count + systemAudio.recoveryIssues.count

        if total > 0, !isRecoveryNoticeDismissed {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Unfinished recording files found", tableName: "TranscriptUI")
                        .font(.caption.weight(.semibold))
                    Text(
                        "Bardo left files from an interrupted recording untouched. They do not block new recordings.",
                        tableName: "TranscriptUI"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("\(total)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)

                Button {
                    isRecoveryNoticeDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("Dismiss recovery notice", tableName: "TranscriptUI"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 680)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: BardoDesignMetrics.compactCornerRadius, style: .continuous))
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func transitionPill(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 640)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: BardoDesignMetrics.compactCornerRadius, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func startLastRecording() async {
        switch CaptureMode(rawValue: lastCaptureModeRaw) ?? .microphone {
        case .microphone:
            await startMicrophoneRecording()
        case .systemAudio:
            await startSystemRecording(includeMicrophone: false)
        case .systemAudioAndMicrophone:
            await startSystemRecording(includeMicrophone: true)
        }
    }

    @MainActor
    private func startMicrophoneRecording() async {
        lastCaptureModeRaw = CaptureMode.microphone.rawValue
        warmTranscriptionForRecording()
        library.stopPlayback()
        await microphone.start()
    }

    @MainActor
    private func startSystemRecording(includeMicrophone: Bool) async {
        lastCaptureModeRaw = includeMicrophone
            ? CaptureMode.systemAudioAndMicrophone.rawValue
            : CaptureMode.systemAudio.rawValue
        warmTranscriptionForRecording()
        library.stopPlayback()
        await systemAudio.start(includeMicrophone: includeMicrophone)
    }

    @MainActor
    private func stopMicrophoneRecording() async {
        warmTranscriptionForRecording()
        let recording = await microphone.stop()
        await publishToLibrary(recording)
    }

    @MainActor
    private func stopSystemRecording() async {
        warmTranscriptionForRecording()
        let recording = await systemAudio.stop()
        await publishToLibrary(recording)
    }

    @MainActor
    private func publishToLibrary(_ recording: Recording?) async {
        await library.reload()
        if let recording {
            library.selection = recording.id
            await library.preparePlaybackForSelection()
        }
    }

    private var microphoneAlertTitle: String {
        switch microphone.permissionState {
        case .denied:
            return "Microphone Access Denied"
        case .restricted:
            return "Microphone Access Restricted"
        default:
            return "Microphone Recording Failed"
        }
    }
}
