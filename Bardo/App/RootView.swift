import SwiftUI

struct RootView: View {
    @StateObject private var library = LibraryViewModel()
    @StateObject private var microphone = MicrophoneRecordingController()
    @StateObject private var systemAudio = SystemAudioRecordingController()

    var body: some View {
        LibraryView(model: library)
            .toolbar {
                captureToolbar
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                captureStatusBar
            }
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

    @ToolbarContentBuilder
    private var captureToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if microphone.isRecording {
                Button(role: .destructive) {
                    Task { await stopMicrophoneRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .help("Stop microphone recording")
            } else if systemAudio.isRecording {
                Button(role: .destructive) {
                    Task { await stopSystemRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .help("Stop system audio recording")
            } else {
                Menu {
                    Button {
                        Task {
                            library.stopPlayback()
                            await microphone.start()
                        }
                    } label: {
                        Label("Microphone", systemImage: "mic")
                    }

                    Divider()

                    Button {
                        Task { await startSystemRecording(includeMicrophone: false) }
                    } label: {
                        Label("System Audio", systemImage: "display")
                    }

                    Button {
                        Task { await startSystemRecording(includeMicrophone: true) }
                    } label: {
                        Label("System Audio + Microphone", systemImage: "person.wave.2")
                    }
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start a new recording")
                .disabled(microphone.isBusy || systemAudio.isBusy)
            }
        }
    }

    @ViewBuilder
    private var captureStatusBar: some View {
        if microphone.phase != .idle && microphone.phase != .failed {
            microphoneStatusBar
        } else if systemAudio.phase != .idle && systemAudio.phase != .failed {
            systemAudioStatusBar
        } else {
            recoveryStatusBar
        }
    }

    @ViewBuilder
    private var microphoneStatusBar: some View {
        switch microphone.phase {
        case .requestingPermission:
            transitionBar(
                title: "Waiting for Microphone Access",
                detail: "Use the macOS permission prompt to allow Bardo to record your microphone."
            )
        case .preparing:
            transitionBar(
                title: "Preparing Microphone",
                detail: "Bardo is preparing the input and a local managed audio file."
            )
        case .recording:
            activeRecordingBar(
                title: "Recording Microphone",
                detail: microphone.inputDisplayName ?? "Default microphone",
                duration: microphone.elapsedTime,
                stopAction: {
                    Task { await stopMicrophoneRecording() }
                }
            )
        case .finalizing:
            transitionBar(
                title: "Saving Recording",
                detail: "Bardo is validating the audio and adding it to your Library."
            )
        case .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var systemAudioStatusBar: some View {
        switch systemAudio.phase {
        case .requestingMicrophonePermission:
            transitionBar(
                title: "Waiting for Microphone Access",
                detail: "Microphone access is needed only for the combined recording mode."
            )
        case .selectingContent:
            transitionBar(
                title: "Choose What to Record",
                detail: "Use the macOS sharing picker to choose a display, app, or window."
            )
        case .preparing:
            transitionBar(
                title: "Preparing System Audio",
                detail: systemAudio.includesMicrophone
                    ? "Bardo is preparing independent system and microphone tracks."
                    : "Bardo is preparing a local system-audio capture file."
            )
        case .recording:
            activeRecordingBar(
                title: systemAudio.includesMicrophone ? "Recording System + Microphone" : "Recording System Audio",
                detail: systemAudio.includesMicrophone
                    ? "Both original sources are being preserved separately."
                    : "Audio from your selected macOS content is being captured.",
                duration: systemAudio.elapsedTime,
                changeSourceAction: {
                    systemAudio.changeSelection()
                },
                stopAction: {
                    Task { await stopSystemRecording() }
                }
            )
        case .changingSelection:
            activeRecordingBar(
                title: "Recording — Choose a New Source",
                detail: "Recording continues while the macOS sharing picker is open.",
                duration: systemAudio.elapsedTime,
                stopAction: {
                    Task { await stopSystemRecording() }
                }
            )
        case .finalizing:
            transitionBar(
                title: "Saving Recording",
                detail: systemAudio.includesMicrophone
                    ? "Bardo is closing the originals, aligning sources, and preparing playback."
                    : "Bardo is validating the audio and adding it to your Library."
            )
        case .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var recoveryStatusBar: some View {
        let microphoneCount = microphone.recoveryIssues.count
        let systemCount = systemAudio.recoveryIssues.count
        let total = microphoneCount + systemCount

        if total > 0 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Incomplete Capture Preserved")
                        .font(.callout.weight(.medium))
                    Text("Bardo preserved \(total) incomplete capture\(total == 1 ? "" : "s") for recovery instead of deleting them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }

    private func activeRecordingBar(
        title: String,
        detail: String,
        duration: TimeInterval,
        changeSourceAction: (() -> Void)? = nil,
        stopAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(durationText(duration))
                        .font(.callout.monospacedDigit())
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let changeSourceAction {
                Button("Change Source…", action: changeSourceAction)
                    .help("Choose different macOS content without restarting the recording")
            }

            Button("Stop", role: .destructive, action: stopAction)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func transitionBar(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(title)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @MainActor
    private func startSystemRecording(includeMicrophone: Bool) async {
        library.stopPlayback()
        await systemAudio.start(includeMicrophone: includeMicrophone)
    }

    @MainActor
    private func stopMicrophoneRecording() async {
        let recording = await microphone.stop()
        await publishToLibrary(recording)
    }

    @MainActor
    private func stopSystemRecording() async {
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

private func durationText(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration.rounded()))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}
