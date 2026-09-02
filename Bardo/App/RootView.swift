import SwiftUI

struct RootView: View {
    private let warmTranscriptionForRecording: @MainActor () -> Void

    @StateObject private var library = LibraryViewModel()
    @StateObject private var microphone = MicrophoneRecordingController()
    @StateObject private var systemAudio = SystemAudioRecordingController()
    @State private var isRecoveryPresented = false

    init(warmTranscriptionForRecording: @escaping @MainActor () -> Void = {}) {
        self.warmTranscriptionForRecording = warmTranscriptionForRecording
    }

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
            .sheet(isPresented: $isRecoveryPresented) {
                RecoveryReviewView(
                    microphoneIssues: microphone.recoveryIssues,
                    systemAudioIssues: systemAudio.recoveryIssues,
                    openMicrophoneFolder: { microphone.openRecoveryFolder() },
                    openSystemAudioFolder: { systemAudio.openRecoveryFolder() },
                    discardMicrophoneIssue: { issue in Task { await microphone.discardRecoveryIssue(issue) } },
                    discardSystemAudioIssue: { issue in Task { await systemAudio.discardRecoveryIssue(issue) } }
                )
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
        ToolbarItem(placement: .automatic) {
            if microphone.isRecording {
                Button {
                    Task { await stopMicrophoneRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .help("Stop microphone recording")
            } else if systemAudio.isRecording {
                Button {
                    Task { await stopSystemRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .help("Stop system audio recording")
            } else {
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
                .padding(.horizontal, 18)
                .padding(.top, 8)
        } else if systemAudio.phase != .idle && systemAudio.phase != .failed {
            systemAudioStatusBar
                .padding(.horizontal, 18)
                .padding(.top, 8)
        } else {
            recoveryStatusBar
        }
    }

    @ViewBuilder
    private var microphoneStatusBar: some View {
        switch microphone.phase {
        case .requestingPermission:
            transitionPill(
                title: "Waiting for Microphone Permission",
                detail: "Respond to the macOS permission prompt."
            )
        case .preparing:
            transitionPill(
                title: "Preparing Recording",
                detail: "Preparing the microphone and managed capture file."
            )
        case .recording:
            activeRecordingPill(
                title: "Recording Microphone",
                detail: microphone.inputDisplayName ?? "Default microphone",
                duration: microphone.elapsedTime,
                stopAction: {
                    Task { await stopMicrophoneRecording() }
                }
            )
        case .finalizing:
            transitionPill(
                title: "Finishing Recording",
                detail: "Closing, validating, and adding the audio to Library."
            )
        case .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var systemAudioStatusBar: some View {
        switch systemAudio.phase {
        case .requestingMicrophonePermission:
            transitionPill(
                title: "Waiting for Microphone Permission",
                detail: "Microphone access is required only for the combined recording mode."
            )
        case .selectingContent:
            transitionPill(
                title: "Choose Audio to Capture",
                detail: "Use the macOS sharing picker to choose a display, app, or window."
            )
        case .preparing:
            transitionPill(
                title: "Preparing System Audio",
                detail: systemAudio.includesMicrophone
                    ? "Preparing independent system and microphone tracks."
                    : "Preparing the system-audio capture file."
            )
        case .recording:
            activeRecordingPill(
                title: systemAudio.includesMicrophone ? "Recording System + Microphone" : "Recording System Audio",
                detail: systemAudio.includesMicrophone
                    ? "Both original sources are being preserved separately."
                    : "Audio from the selected macOS content is being captured.",
                duration: systemAudio.elapsedTime,
                changeSourceAction: {
                    systemAudio.changeSelection()
                },
                stopAction: {
                    Task { await stopSystemRecording() }
                }
            )
        case .changingSelection:
            activeRecordingPill(
                title: "Recording — Choose New Source",
                detail: "Capture continues while the macOS sharing picker is open.",
                duration: systemAudio.elapsedTime,
                stopAction: {
                    Task { await stopSystemRecording() }
                }
            )
        case .finalizing:
            transitionPill(
                title: "Finishing System Audio",
                detail: systemAudio.includesMicrophone
                    ? "Closing originals, aligning sources, and preparing playback."
                    : "Closing, validating, and adding system audio to Library."
            )
        case .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var recoveryStatusBar: some View {
        let total = microphone.recoveryIssues.count + systemAudio.recoveryIssues.count

        if total > 0 {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recovery files need your attention")
                        .font(.callout.weight(.semibold))
                    Text("\(total) interrupted capture\(total == 1 ? "" : "s") are safe in Bardo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Review files…") { isRecoveryPresented = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .help("Review, open, or discard interrupted capture files")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 720, minHeight: 52)
            .bardoGlassSurface(cornerRadius: 16)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.orange)
                    .frame(width: 3, height: 28)
                    .padding(.leading, 7)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recovery files need your attention. \(total) interrupted capture\(total == 1 ? "" : "s") are safe in Bardo. Review files.")
        }
    }

    private func activeRecordingPill(
        title: String,
        detail: String,
        duration: TimeInterval,
        changeSourceAction: (() -> Void)? = nil,
        stopAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .font(.title3)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(LibraryFormatting.duration(duration))
                        .font(.callout.monospacedDigit())
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 18)

            if let changeSourceAction {
                Button("Change Source…", action: changeSourceAction)
                    .help("Choose different macOS content without restarting the recording")
            }

            Button("Stop", role: .destructive, action: stopAction)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .bardoGlassSurface(cornerRadius: 18, interactive: true)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(LibraryFormatting.duration(duration)) elapsed. \(detail)")
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
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 640)
        .bardoGlassSurface(cornerRadius: 18)
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func startMicrophoneRecording() async {
        warmTranscriptionForRecording()
        library.stopPlayback()
        await microphone.start()
    }

    @MainActor
    private func startSystemRecording(includeMicrophone: Bool) async {
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

private struct RecoveryReviewView: View {
    let microphoneIssues: [RecordingStoreIssue]
    let systemAudioIssues: [RecordingStoreIssue]
    let openMicrophoneFolder: () -> Bool
    let openSystemAudioFolder: () -> Bool
    let discardMicrophoneIssue: (RecordingStoreIssue) -> Void
    let discardSystemAudioIssue: (RecordingStoreIssue) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Recovery", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Text("Bardo preserved these incomplete capture files after an interruption. Review them in Finder, or discard only the items you no longer need.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    issueSection("Microphone captures", issues: microphoneIssues, openFolder: openMicrophoneFolder, discard: discardMicrophoneIssue)
                    issueSection("System audio captures", issues: systemAudioIssues, openFolder: openSystemAudioFolder, discard: discardSystemAudioIssue)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func issueSection(
        _ title: String,
        issues: [RecordingStoreIssue],
        openFolder: @escaping () -> Bool,
        discard: @escaping (RecordingStoreIssue) -> Void
    ) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button("Open in Finder") { _ = openFolder() }
                }
                ForEach(issues) { issue in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.entryName).lineLimit(1)
                            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if issue.recordingID != nil {
                            Button("Discard", role: .destructive) { discard(issue) }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
