import Foundation
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
                    moveMicrophoneIssueToTrash: { issue in Task { await microphone.moveRecoveryIssueToTrash(issue) } },
                    moveSystemAudioIssueToTrash: { issue in Task { await systemAudio.moveRecoveryIssueToTrash(issue) } }
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
                    Text(RecoveryCopy.countDescription(total))
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
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recovery files need your attention. \(RecoveryCopy.countDescription(total)). Review files.")
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

private enum RecoveryCopy {
    static let title = String(localized: "Interrupted captures")
    static let close = String(localized: "Close")
    static let reviewDescription = String(localized: "Bardo found incomplete captures after an interruption. They are still safe on your Mac. Review them in Finder or move the ones you do not need to the Trash.")
    static let openInFinder = String(localized: "Open in Finder")
    static let moveToTrash = String(localized: "Move to Trash…")
    static let moveToTrashTitle = String(localized: "Move capture to the Trash?")
    static let moveToTrashAction = String(localized: "Move to Trash")
    static let cancel = String(localized: "Cancel")
    static let allClearTitle = String(localized: "All clear")
    static let allClearDescription = String(localized: "There are no incomplete captures waiting for review.")

    static func countDescription(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 interrupted capture is safe in Bardo")
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld interrupted captures are safe in Bardo"),
            count
        )
    }

    static func sectionTitle(for source: RecoveryReviewView.Source) -> String {
        switch source {
        case .microphone:
            return String(localized: "Microphone capture")
        case .systemAudio:
            return String(localized: "System audio capture")
        }
    }

    static func technicalID(_ id: String) -> String {
        String.localizedStringWithFormat(String(localized: "Technical ID: %@"), id)
    }

    static func preservedMessage(for source: RecoveryReviewView.Source) -> String {
        switch source {
        case .microphone:
            return String(localized: "An incomplete microphone capture was preserved for recovery.")
        case .systemAudio:
            return String(localized: "An incomplete system-audio capture was preserved for recovery.")
        }
    }

    static func moveToTrashMessage(for source: RecoveryReviewView.Source) -> String {
        String.localizedStringWithFormat(
            String(localized: "%@ will be moved to the macOS Trash. You can recover it from there if needed."),
            sectionTitle(for: source)
        )
    }
}

private struct RecoveryReviewView: View {
    enum Source: Hashable {
        case microphone
        case systemAudio
    }

    private struct PendingDiscard: Identifiable {
        let issue: RecordingStoreIssue
        let source: Source

        var id: String { "\(source)-\(issue.id)" }
    }

    let microphoneIssues: [RecordingStoreIssue]
    let systemAudioIssues: [RecordingStoreIssue]
    let openMicrophoneFolder: () -> Bool
    let openSystemAudioFolder: () -> Bool
    let moveMicrophoneIssueToTrash: (RecordingStoreIssue) -> Void
    let moveSystemAudioIssueToTrash: (RecordingStoreIssue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDiscard: PendingDiscard?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(RecoveryCopy.title, systemImage: "arrow.triangle.2.circlepath")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(RecoveryCopy.close) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Text(RecoveryCopy.reviewDescription)
                .foregroundStyle(.secondary)

            if microphoneIssues.isEmpty && systemAudioIssues.isEmpty {
                ContentUnavailableView {
                    Label(RecoveryCopy.allClearTitle, systemImage: "checkmark.circle")
                } description: {
                    Text(RecoveryCopy.allClearDescription)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        issueSection(
                            source: .microphone,
                            issues: microphoneIssues,
                            openFolder: openMicrophoneFolder
                        )
                        issueSection(
                            source: .systemAudio,
                            issues: systemAudioIssues,
                            openFolder: openSystemAudioFolder
                        )
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(RecoveryCopy.close) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealHeight: 390, maxHeight: 620)
        .alert(item: $pendingDiscard) { pending in
            Alert(
                title: Text(RecoveryCopy.moveToTrashTitle),
                message: Text(RecoveryCopy.moveToTrashMessage(for: pending.source)),
                primaryButton: .destructive(Text(RecoveryCopy.moveToTrashAction)) {
                    switch pending.source {
                    case .microphone:
                        moveMicrophoneIssueToTrash(pending.issue)
                    case .systemAudio:
                        moveSystemAudioIssueToTrash(pending.issue)
                    }
                },
                secondaryButton: .cancel(Text(RecoveryCopy.cancel))
            )
        }
    }

    @ViewBuilder
    private func issueSection(
        source: Source,
        issues: [RecordingStoreIssue],
        openFolder: @escaping () -> Bool
    ) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(RecoveryCopy.sectionTitle(for: source), systemImage: source == .microphone ? "mic" : "waveform")
                        .font(.headline)
                    Spacer()
                    Button(RecoveryCopy.openInFinder) { _ = openFolder() }
                }
                ForEach(issues) { issue in
                    HStack(spacing: 10) {
                        Image(systemName: source == .microphone ? "mic.fill" : "waveform")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RecoveryCopy.sectionTitle(for: source))
                                .font(.body.weight(.medium))
                            Text(RecoveryCopy.technicalID(issue.entryName))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Text(RecoveryCopy.preservedMessage(for: source))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if issue.recordingID != nil {
                            Button(RecoveryCopy.moveToTrash) {
                                pendingDiscard = PendingDiscard(issue: issue, source: source)
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
