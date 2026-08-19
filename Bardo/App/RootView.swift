import SwiftUI

struct RootView: View {
    @StateObject private var library = LibraryViewModel()
    @StateObject private var microphone = MicrophoneRecordingController()

    var body: some View {
        LibraryView(model: library)
            .toolbar {
                Button {
                    Task {
                        if microphone.isRecording {
                            await stopAndPublishRecording()
                        } else {
                            library.stopPlayback()
                            await microphone.start()
                        }
                    }
                } label: {
                    Label(
                        microphone.isRecording ? "Stop Recording" : "Record",
                        systemImage: microphone.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .help(microphone.isRecording ? "Stop microphone recording" : "Record from microphone")
                .disabled(!microphone.isRecording && microphone.isBusy)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                microphoneStatusBar
            }
            .task {
                microphone.refreshPermissionState()
                await microphone.refreshRecoveryIssues()
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
            .onDisappear {
                guard microphone.requiresTerminationFinalization else { return }
                Task {
                    await microphone.prepareForApplicationTermination()
                    await library.reload()
                }
            }
    }

    @ViewBuilder
    private var microphoneStatusBar: some View {
        switch microphone.phase {
        case .requestingPermission:
            transitionBar(
                title: "Waiting for Microphone Permission",
                detail: "Respond to the macOS permission prompt."
            )
        case .preparing:
            transitionBar(
                title: "Preparing Recording",
                detail: "Preparing the microphone and managed capture file."
            )
        case .recording:
            HStack(spacing: 12) {
                Image(systemName: "record.circle.fill")
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Recording")
                            .fontWeight(.semibold)
                        Text(durationText(microphone.elapsedTime))
                            .monospacedDigit()
                    }
                    Text(microphone.inputDisplayName ?? "Default microphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Stop", role: .destructive) {
                    Task { await stopAndPublishRecording() }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Recording from \(microphone.inputDisplayName ?? "the default microphone"), \(durationText(microphone.elapsedTime)) elapsed"
            )
        case .finalizing:
            transitionBar(
                title: "Finishing Recording",
                detail: "Closing, validating, and adding the audio to Library."
            )
        case .idle, .failed:
            if !microphone.recoveryIssues.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Bardo preserved \(microphone.recoveryIssues.count) incomplete microphone capture\(microphone.recoveryIssues.count == 1 ? "" : "s") for recovery.")
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private func transitionBar(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @MainActor
    private func stopAndPublishRecording() async {
        let recording = await microphone.stop()
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
