import Foundation
import SwiftUI

struct RootView: View {
    @ObserveInjection var redraw
    private let warmTranscriptionForRecording: @MainActor () -> Void
    private let setupBanner: AnyView?

    @StateObject private var library = LibraryViewModel()
    @StateObject private var microphone = MicrophoneRecordingController()
    @StateObject private var systemAudio = SystemAudioRecordingController()
    @State private var isRecoveryPresented = false
    @State private var isRecordingSetupPresented = false

    init(
        warmTranscriptionForRecording: @escaping @MainActor () -> Void = {},
        setupBanner: AnyView? = nil
    ) {
        self.warmTranscriptionForRecording = warmTranscriptionForRecording
        self.setupBanner = setupBanner
    }

    var body: some View {
        LibraryView(
            model: library,
            captureMenu: AnyView(captureMenuButton),
            activeCaptureBanner: activeCaptureBanner,
            onNewRecording: presentRecordingSetup
        )
            .task {
                let publish: (Recording) -> Void = { recording in
                    Task { await publishToLibrary(recording) }
                }
                microphone.onRecordingPublished = publish
                systemAudio.onRecordingPublished = publish
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
                    Button(String(localized: "Open System Settings")) {
                        _ = microphone.openMicrophoneSystemSettings()
                    }
                }
                Button(String(localized: "OK"), role: .cancel) {
                    microphone.clearError()
                }
            } message: {
                Text(microphone.errorMessage ?? String(localized: "Microphone recording could not continue."))
            }
            .alert(
                String(localized: "System Audio Recording"),
                isPresented: Binding(
                    get: { systemAudio.errorMessage != nil },
                    set: { if !$0 { systemAudio.clearError() } }
                )
            ) {
                Button(String(localized: "OK"), role: .cancel) {
                    systemAudio.clearError()
                }
            } message: {
                Text(systemAudio.errorMessage ?? String(localized: "System audio recording could not continue."))
            }
            .sheet(isPresented: $isRecoveryPresented) {
                RecoveryReviewView(
                    microphoneIssues: microphone.recoveryIssues,
                    systemAudioIssues: systemAudio.recoveryIssues,
                    isRecovering: microphone.isRecovering || systemAudio.isRecovering,
                    canRecover: !microphone.isBusy && !systemAudio.isBusy,
                    openMicrophoneFolder: { microphone.openRecoveryFolder() },
                    openSystemAudioFolder: { systemAudio.openRecoveryFolder() },
                    recoverMicrophoneIssue: { issue in Task { await microphone.recoverRecoveryIssue(issue) } },
                    recoverSystemAudioIssue: { issue in Task { await systemAudio.recoverRecoveryIssue(issue) } },
                    recoverAllIssues: {
                        Task {
                            for issue in microphone.recoveryIssues where issue.recordingID != nil {
                                await microphone.recoverRecoveryIssue(issue)
                            }
                            for issue in systemAudio.recoveryIssues where issue.recordingID != nil {
                                await systemAudio.recoverRecoveryIssue(issue)
                            }
                        }
                    },
                    moveMicrophoneIssueToTrash: { issue in Task { await microphone.moveRecoveryIssueToTrash(issue) } },
                    moveSystemAudioIssueToTrash: { issue in Task { await systemAudio.moveRecoveryIssueToTrash(issue) } },
                    moveAllIssuesToTrash: {
                        Task {
                            await microphone.moveAllRecoveryIssuesToTrash()
                            await systemAudio.moveAllRecoveryIssuesToTrash()
                        }
                    }
                )
            }
            .sheet(isPresented: $isRecordingSetupPresented) {
                RecordingSetupSheet(microphone: microphone) { mode, title in
                    beginRecording(mode: mode, title: title)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.newRecording)) { _ in
                presentRecordingSetup()
            }
            .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.pauseRecording)) { _ in
                if microphone.phase == .recording {
                    microphone.pause()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.resumeRecording)) { _ in
                if microphone.phase == .paused {
                    microphone.resume()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.stopRecording)) { _ in
                Task {
                    if microphone.phase == .recording || microphone.phase == .paused {
                        await stopMicrophoneRecording()
                    } else if systemAudio.isRecording {
                        await stopSystemRecording()
                    }
                }
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
            .enableInjection()
    }

    private var activeCaptureBanner: AnyView? {
        if microphone.phase != .idle && microphone.phase != .failed {
            return AnyView(microphoneStatusBar)
        } else if systemAudio.phase != .idle && systemAudio.phase != .failed {
            return AnyView(systemAudioStatusBar)
        } else if !microphone.recoveryIssues.isEmpty || !systemAudio.recoveryIssues.isEmpty {
            return AnyView(recoveryBanner)
        } else {
            return setupBanner
        }
    }

    private var captureMenuButton: some View {
        Button(action: presentRecordingSetup) {
            Label("Nueva grabación", systemImage: "record.circle")
        }
        .help("Nueva grabación (⌘N)")
        .disabled(microphone.isBusy || systemAudio.isBusy)
    }

    @ViewBuilder
    private var microphoneStatusBar: some View {
        switch microphone.phase {
        case .requestingPermission:
            transitionPill(
                title: "Esperando permiso para usar el micrófono",
                detail: "Responde al aviso de macOS para continuar."
            )
        case .preparing:
            transitionPill(
                title: "Preparando la grabación",
                detail: "Comprobando el micrófono y dejando listo el audio."
            )
        case .recording:
            activeRecordingPill(
                title: "Grabando",
                detail: microphone.inputDisplayName ?? "Micrófono del sistema",
                duration: microphone.elapsedTime,
                inputLevel: microphone.inputLevel,
                pauseAction: { microphone.pause() },
                stopAction: {
                    Task { await stopMicrophoneRecording() }
                }
            )
        case .paused:
            activeRecordingPill(
                title: "Grabación en pausa",
                detail: "Reanuda cuando quieras continuar.",
                duration: microphone.elapsedTime,
                inputLevel: 0,
                resumeAction: { microphone.resume() },
                stopAction: {
                    Task { await stopMicrophoneRecording() }
                }
            )
        case .finalizing:
            transitionPill(
                title: "Guardando la grabación",
                detail: "Terminando de guardar el audio en tu biblioteca."
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
                title: "Esperando permiso para usar el micrófono",
                detail: "Lo necesitamos para incluir tu voz junto al audio del Mac."
            )
        case .selectingContent:
            transitionPill(
                title: "Elige qué quieres grabar",
                detail: "Selecciona una app, ventana o pantalla en el selector de macOS.",
                cancelAction: { systemAudio.cancelContentSelection() }
            )
        case .preparing:
            transitionPill(
                title: "Preparando la grabación",
                detail: systemAudio.includesMicrophone
                    ? "Dejando listas tu voz y el audio del Mac."
                    : "Dejando listo el audio del Mac."
            )
        case .recording:
            activeRecordingPill(
                title: "Grabando",
                detail: systemAudio.captureWarning ?? (systemAudio.includesMicrophone
                    ? "Tu voz y el audio del Mac se están guardando por separado."
                    : "Grabando el audio del contenido que elegiste."),
                duration: systemAudio.elapsedTime,
                isWarning: systemAudio.captureWarning != nil,
                changeSourceAction: {
                    systemAudio.changeSelection()
                },
                stopAction: {
                    Task { await stopSystemRecording() }
                }
            )
        case .changingSelection:
            activeRecordingPill(
                title: "Grabando · elige otra fuente",
                detail: "La grabación continúa mientras eliges otro contenido.",
                duration: systemAudio.elapsedTime,
                stopAction: {
                    Task { await stopSystemRecording() }
                }
            )
        case .finalizing:
            transitionPill(
                title: "Guardando la grabación",
                detail: systemAudio.includesMicrophone
                    ? "Organizando las pistas y preparando el audio."
                    : "Terminando de guardar el audio en tu biblioteca."
            )
        case .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var recoveryBanner: some View {
        let total = microphone.recoveryIssues.count + systemAudio.recoveryIssues.count

        if total > 0 {
            GroupBox {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(RecoveryCopy.reviewTitle(total))
                            .font(.callout.weight(.semibold))
                        Text(RecoveryCopy.countDescription(total))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Button(RecoveryCopy.reviewAction) {
                        isRecoveryPresented = true
                    }
                    .controlSize(.small)
                    .help(String(localized: "Review, open, or discard interrupted capture files"))
                }
            }
            .frame(maxWidth: 720)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(RecoveryCopy.reviewTitle(total)). \(RecoveryCopy.reviewDetail(total)). \(RecoveryCopy.reviewAction)")
        }
    }

    private func activeRecordingPill(
        title: String,
        detail: String,
        duration: TimeInterval,
        inputLevel: Double? = nil,
        isWarning: Bool = false,
        pauseAction: (() -> Void)? = nil,
        resumeAction: (() -> Void)? = nil,
        changeSourceAction: (() -> Void)? = nil,
        stopAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                        Text(LibraryFormatting.duration(duration))
                            .font(.callout.monospacedDigit())

                        if let inputLevel {
                            BardoInputLevelView(level: inputLevel)
                        }
                    }

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .help(detail)
                }

                Spacer(minLength: 16)

                if let pauseAction {
                    Button(action: pauseAction) {
                        Label(String(localized: "Pause"), systemImage: "pause.fill")
                    }
                    .controlSize(.small)
                    .help(String(localized: "Pause recording"))
                }

                if let resumeAction {
                    Button(action: resumeAction) {
                        Label(String(localized: "Resume"), systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .help(String(localized: "Resume recording"))
                }

                if let changeSourceAction {
                    Button(String(localized: "Change Source…"), action: changeSourceAction)
                        .controlSize(.small)
                        .help(String(localized: "Choose different macOS content without restarting the recording"))
                }

                Button(action: stopAction) {
                    Label("Finalizar", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .help(String(localized: "Stop recording (⌘.)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 720)
        .bardoGlassSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(LibraryFormatting.duration(duration)). \(detail)")
    }

    private func transitionPill(
        title: String,
        detail: String,
        cancelAction: (() -> Void)? = nil
    ) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let cancelAction {
                    Button(String(localized: "Cancel"), role: .cancel, action: cancelAction)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: 720)
    }

    private func presentRecordingSetup() {
        guard !microphone.isBusy, !systemAudio.isBusy else { return }
        isRecordingSetupPresented = true
    }

    private func beginRecording(mode: BardoRecordingMode, title: String?) {
        switch mode {
        case .microphone:
            Task { await startMicrophoneRecording(title: title) }
        case .conversation:
            Task { await startSystemRecording(includeMicrophone: true, title: title) }
        case .systemAudio:
            Task { await startSystemRecording(includeMicrophone: false, title: title) }
        }
    }

    @MainActor
    private func startMicrophoneRecording(title: String?) async {
        warmTranscriptionForRecording()
        library.stopPlayback()
        await microphone.start(title: title)
    }

    @MainActor
    private func startSystemRecording(includeMicrophone: Bool, title: String?) async {
        warmTranscriptionForRecording()
        library.stopPlayback()
        await systemAudio.start(includeMicrophone: includeMicrophone, title: title)
    }

    /// Recordings reach the Library through each controller's publication callback,
    /// which also covers interruptions that kept audio and recovered captures.
    @MainActor
    private func stopMicrophoneRecording() async {
        warmTranscriptionForRecording()
        _ = await microphone.stop()
    }

    @MainActor
    private func stopSystemRecording() async {
        warmTranscriptionForRecording()
        _ = await systemAudio.stop()
    }

    @MainActor
    private func publishToLibrary(_ recording: Recording) async {
        await library.reload()
        library.selection = recording.id
        await library.preparePlaybackForSelection()
    }

    private var microphoneAlertTitle: String {
        switch microphone.permissionState {
        case .denied:
            return "Bardo no tiene acceso al micrófono"
        case .restricted:
            return "El micrófono no está disponible"
        default:
            return "No pudimos iniciar la grabación"
        }
    }
}

private enum RecoveryCopy {
    static let title = String(localized: "Interrupted recordings")
    static let close = String(localized: "Close")
    static let reviewDescription = String(localized: "Bardo found recordings that were interrupted before they could be saved. Recover them to add the audio captured until the interruption to your library, or move the ones you do not need to the Trash.")
    static let openInFinder = String(localized: "Open in Finder")
    static let moveToTrash = String(localized: "Move to Trash…")
    static let moveToTrashTitle = String(localized: "Move capture to the Trash?")
    static let moveToTrashAction = String(localized: "Move to Trash")
    static let moveAllToTrash = String(localized: "Move all to the Trash…")
    static let moveAllToTrashAction = String(localized: "Move All to Trash")
    static let cancel = String(localized: "Cancel")
    static let allClearTitle = String(localized: "All clear")
    static let allClearDescription = String(localized: "There are no incomplete captures waiting for review.")
    static let reviewAction = String(localized: "Review recordings…")
    static let recover = String(localized: "Recover")
    static let recoverAll = String(localized: "Recover All")
    static let recovering = String(localized: "Recovering…")
    static let recoverHelp = String(localized: "Add the audio captured before the interruption to your library")

    static func reviewTitle(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: count == 1
                ? "1 interrupted recording needs review"
                : "%lld interrupted recordings need review"),
            count
        )
    }

    static func reviewDetail(_ count: Int) -> String {
        String(localized: count == 1
            ? "Bardo recovered it and it’s safe."
            : "Bardo recovered them and they’re safe.")
    }

    static func moveAllToTrashTitle(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: count == 1 ? "Move 1 capture to the Trash?" : "Move %lld captures to the Trash?"),
            count
        )
    }

    static func moveAllToTrashMessage(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: count == 1
                ? "This capture will be moved to the macOS Trash. You can recover it later if needed."
                : "These %lld captures will be moved to the macOS Trash. You can recover them later if needed."),
            count
        )
    }

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
    let isRecovering: Bool
    let canRecover: Bool
    let openMicrophoneFolder: () -> Bool
    let openSystemAudioFolder: () -> Bool
    let recoverMicrophoneIssue: (RecordingStoreIssue) -> Void
    let recoverSystemAudioIssue: (RecordingStoreIssue) -> Void
    let recoverAllIssues: () -> Void
    let moveMicrophoneIssueToTrash: (RecordingStoreIssue) -> Void
    let moveSystemAudioIssueToTrash: (RecordingStoreIssue) -> Void
    let moveAllIssuesToTrash: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDiscard: PendingDiscard?
    @State private var isBulkDiscardConfirmationPresented = false

    #if DEBUG
    @ObserveInjection var forceRedraw
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(RecoveryCopy.title)
                .font(.title2.weight(.semibold))

            Text(RecoveryCopy.reviewDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
            HStack(spacing: 12) {
                if actionableIssueCount > 0 {
                    Button(RecoveryCopy.moveAllToTrash) {
                        isBulkDiscardConfirmationPresented = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(isRecovering)
                }
                Spacer()
                if isRecovering {
                    ProgressView()
                        .controlSize(.small)
                    Text(RecoveryCopy.recovering)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if actionableIssueCount > 0 {
                    Button(RecoveryCopy.recoverAll, action: recoverAllIssues)
                        .disabled(isRecovering || !canRecover)
                        .help(RecoveryCopy.recoverHelp)
                }
                Button(RecoveryCopy.close) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealHeight: 360, maxHeight: 620)
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
        .confirmationDialog(
            RecoveryCopy.moveAllToTrashTitle(actionableIssueCount),
            isPresented: $isBulkDiscardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(RecoveryCopy.moveAllToTrashAction, role: .destructive) {
                moveAllIssuesToTrash()
            }
            Button(RecoveryCopy.cancel, role: .cancel) {}
        } message: {
            Text(RecoveryCopy.moveAllToTrashMessage(actionableIssueCount))
        }
        .enableInjection()
    }

    private var actionableIssueCount: Int {
        microphoneIssues.filter { $0.recordingID != nil }.count
            + systemAudioIssues.filter { $0.recordingID != nil }.count
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
                VStack(spacing: 0) {
                    ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                        HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.entryName)
                                .font(.body.weight(.medium))
                            Text(RecoveryCopy.preservedMessage(for: source))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if issue.recordingID != nil {
                            Button(RecoveryCopy.recover) {
                                switch source {
                                case .microphone:
                                    recoverMicrophoneIssue(issue)
                                case .systemAudio:
                                    recoverSystemAudioIssue(issue)
                                }
                            }
                            .controlSize(.small)
                            .disabled(isRecovering || !canRecover)
                            .help(RecoveryCopy.recoverHelp)

                            Button(RecoveryCopy.moveToTrash) {
                                pendingDiscard = PendingDiscard(issue: issue, source: source)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .controlSize(.small)
                            .disabled(isRecovering)
                        }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                        if index < issues.count - 1 {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }

            }
        }
    }
}
