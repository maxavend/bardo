import AppKit
import SwiftUI

struct SettingsView: View {
    @ObserveInjection var redraw
    @StateObject private var model = ModelSettingsViewModel()
    @State private var pendingReset: PendingModelReset?

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Privacy")
                            .fontWeight(.semibold)
                        Text("Your recordings and transcripts stay on this Mac. Bardo does not upload audio to the internet.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Whisper Large v3 Turbo"))
                            .fontWeight(.semibold)
                        Text(String(localized: "The only transcription engine. It keeps word timestamps and processes audio locally."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label(String(localized: "Transcription"), systemImage: "waveform")
            }

            Section {
                if model.rows.isEmpty {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking local models…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.rows) { row in
                        ModelSettingsRow(row: row) { action in
                            handle(action, for: row.id)
                        }
                    }
                }
            } header: {
                HStack {
                    Label("Local Models", systemImage: "cpu")
                    Spacer()
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Check Models") {
                        model.refresh()
                    }
                    .buttonStyle(.link)
                    .disabled(model.isRefreshing)
                }
            } footer: {
                Text("Whisper Turbo, SpeakerKit, and meeting minutes run locally on this Mac.")
            }

            Section {
                LabeledContent("Model folder") {
                    Button("Show in Finder") {
                        model.revealModelsFolder()
                    }
                }
            } header: {
                Label("Storage", systemImage: "externaldrive")
            } footer: {
                Text("Models are stored privately on your Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 600, minHeight: 520)
        .task {
            await model.refreshIfNeeded()
        }
        .alert(item: $pendingReset) { request in
            let message = String(localized: "This removes the selected model’s private files.")
            return Alert(
                title: Text("Remove local model?"),
                message: Text(message),
                primaryButton: .destructive(Text(request.reinstall ? "Remove and Download Again" : "Remove Model")) {
                    if request.reinstall {
                        model.resetAndInstall(request.model)
                    } else {
                        model.reset(request.model)
                    }
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
        .enableInjection()
    }

    private func handle(_ action: ModelSettingsAction, for modelID: ManagedModel) {
        switch action {
        case .install:
            model.install(modelID)
        case .cancel:
            model.cancel(modelID)
        case .retry:
            model.install(modelID)
        case .reset:
            pendingReset = PendingModelReset(model: modelID, reinstall: false)
        case .resetAndInstall:
            pendingReset = PendingModelReset(model: modelID, reinstall: true)
        case .reveal:
            model.revealModelFolder(modelID)
        case .unavailable:
            break
        }
    }
}

private struct PendingModelReset: Identifiable {
    let model: ManagedModel
    let reinstall: Bool

    var id: String { "\(model.rawValue)-\(reinstall)" }
}

private struct ModelSettingsRow: View {
    let row: ModelSettingsRowState
    let action: (ModelSettingsAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: row.symbol)
                        .foregroundStyle(row.stateColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !row.stateLabel.isEmpty {
                    Text(row.stateLabel)
                        .font(.caption)
                        .foregroundStyle(row.stateColor)
                        .lineLimit(1)
                }

                stateControl
            }

            if let progress = row.progressFraction {
                ProgressView(value: progress)
            }

            if case .failed(let message) = row.state {
                Text(String.localizedStringWithFormat(String(localized: "Failed: %@"), message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [row.title, row.stateLabel, row.detail]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var stateControl: some View {
        switch row.primaryAction {
        case .install:
            Button(String(localized: "Install")) {
                action(.install)
            }
            .controlSize(.small)

        case .cancel:
            Button(String(localized: "Cancel"), role: .cancel) {
                action(.cancel)
            }
            .controlSize(.small)

        case .retry:
            Button(String(localized: "Retry")) {
                action(.retry)
            }
            .controlSize(.small)

        case .reset, .resetAndInstall:
            Menu {
                Button(String(localized: "Show in Finder")) {
                    action(.reveal)
                }

                Divider()

                Button(String(localized: "Reinstall Model…"), role: .destructive) {
                    action(.resetAndInstall)
                }

                Button(String(localized: "Remove Model"), role: .destructive) {
                    action(.reset)
                }
            } label: {
                Label(
                    String.localizedStringWithFormat(String(localized: "More actions for %@"), row.title),
                    systemImage: "ellipsis.circle"
                )
                .labelStyle(.iconOnly)
            }
            .controlSize(.small)
            .help(String(localized: "Show more actions"))

        case .reveal, .unavailable:
            EmptyView()
        }
    }
}

struct ModelSettingsRowState: Identifiable, Equatable, Sendable {
    let id: ManagedModel
    let title: String
    let detail: String
    let supportsInstallation: Bool
    var state: ManagedModelState

    var primaryAction: ModelSettingsAction {
        ModelSettingsActionPolicy.action(for: state, supportsInstallation: supportsInstallation)
    }

    var stateLabel: String {
        switch state {
        case .notInstalled:
            return supportsInstallation ? "" : String(localized: "On demand")
        case .downloading(let fraction):
            return String.localizedStringWithFormat(String(localized: "Downloading %@"), percentage(fraction))
        case .preparing(let fraction):
            return String.localizedStringWithFormat(String(localized: "Preparing %@"), percentage(fraction))
        case .installed:
            return String(localized: "Installed")
        case .failed:
            return String(localized: "Failed")
        }
    }

    var progressFraction: Double? {
        switch state {
        case .downloading(let fraction), .preparing(let fraction):
            return min(1, max(0, fraction))
        default:
            return nil
        }
    }

    var symbol: String {
        switch state {
        case .notInstalled: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.fill"
        case .preparing: return "gearshape"
        case .installed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    var stateColor: Color {
        switch state {
        case .notInstalled: return .secondary
        case .downloading, .preparing: return .secondary
        case .installed: return .green
        case .failed: return .orange
        }
    }

    private func percentage(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

@MainActor
private final class ModelSettingsViewModel: ObservableObject {
    @Published private(set) var rows: [ModelSettingsRowState] = []
    @Published private(set) var isRefreshing = false
    private var didRefresh = false
    private var refreshTask: Task<Void, Never>?
    private var operationTasks: [ManagedModel: Task<Void, Never>] = [:]

    init() {
        rows = ManagedModel.allCases.map { makeRow(for: $0, state: .notInstalled) }
    }

    deinit {
        refreshTask?.cancel()
        operationTasks.values.forEach { $0.cancel() }
    }

    func refreshIfNeeded() async {
        guard !didRefresh else { return }
        await refreshAsync()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshAsync()
        }
    }

    func install(_ model: ManagedModel) {
        guard operationTasks[model] == nil else { return }
        setState(.downloading(0), for: model)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runInstall(model)
        }
        operationTasks[model] = task
    }

    func cancel(_ model: ManagedModel) {
        operationTasks[model]?.cancel()
    }

    func reset(_ model: ManagedModel) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await resetRuntimeModel(model)
                setState(.notInstalled, for: model)
            } catch {
                setState(.failed(error.localizedDescription), for: model)
            }
        }
    }

    func resetAndInstall(_ model: ManagedModel) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await resetRuntimeModel(model)
                setState(.notInstalled, for: model)
                install(model)
            } catch {
                setState(.failed(error.localizedDescription), for: model)
            }
        }
    }

    private func resetRuntimeModel(_ model: ManagedModel) async throws {
        switch model {
        case .whisperTurbo:
            try await WhisperTranscriptionService.live().reset()
        case .speakerKit:
            try await SpeakerDiarizationService.live().reset()
        case .meetingMinutes:
            let generator = try? MeetingMinutesGenerator.live()
            await generator?.reset()
        }
        try BardoModelStore.live().reset(model)
    }

    func revealModelsFolder() {
        guard let store = try? BardoModelStore.live() else { return }
        let root = store.root(for: .whisperTurbo).deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func revealModelFolder(_ model: ManagedModel) {
        guard let store = try? BardoModelStore.live() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.root(for: model)])
    }

    private func runInstall(_ model: ManagedModel) async {
        defer { operationTasks[model] = nil }

        do {
            _ = try BardoModelStore.live()
            switch model {
            case .whisperTurbo:
                let manager = try TranscriptionModelManager.live()
                _ = try await manager.ensureResourcesAvailable { fraction in
                    let state = Self.runtimeDownloadState(for: fraction)
                    Task { @MainActor [weak self] in
                        self?.setState(state, for: model)
                    }
                }
            case .speakerKit:
                let service = try SpeakerDiarizationService.live()
                try await service.prepareForUse { snapshot in
                    let state = Self.diarizationState(for: snapshot)
                    Task { @MainActor [weak self] in
                        self?.setState(state, for: model)
                    }
                }
            case .meetingMinutes:
                let manager = try MeetingMinutesModelManager.live()
                try await manager.prepareForUse { fraction in
                    let state = Self.meetingMinutesState(for: fraction)
                    Task { @MainActor [weak self] in
                        self?.setState(state, for: model)
                    }
                }
            }

            try Task.checkCancellation()
            setState(.installed, for: model)
        } catch {
            if error is CancellationError || Task.isCancelled {
                await refreshModel(model)
            } else {
                setState(.failed(error.localizedDescription), for: model)
            }
        }
    }

    private func refreshAsync() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            didRefresh = true
            refreshTask = nil
        }

        do {
            _ = try BardoModelStore.live()
        } catch {
            rows = ManagedModel.allCases.map {
                makeRow(for: $0, state: .failed(error.localizedDescription))
            }
            return
        }
        if operationTasks[.whisperTurbo] == nil {
            do {
                let whisper = try WhisperTranscriptionService.live()
                let installed = await whisper.hasInstalledModel()
                setState(installed ? .installed : .notInstalled, for: .whisperTurbo)
            } catch { setState(.failed(error.localizedDescription), for: .whisperTurbo) }
        }

        if operationTasks[.speakerKit] == nil {
            do {
                let speakers = try SpeakerDiarizationService.live()
                let installed = await speakers.hasInstalledModels()
                if installed {
                    setState(.installed, for: .speakerKit)
                } else {
                    let state = await speakers.state()
                    setState(state == .notInstalled ? .notInstalled : state, for: .speakerKit)
                }
            } catch {
                setState(.failed(error.localizedDescription), for: .speakerKit)
            }
        }

        let minutesInstalled = MeetingMinutesModelResourceResolver.isInstalled()
        setState(minutesInstalled ? .installed : .notInstalled, for: .meetingMinutes)
    }

    private func refreshModel(_ model: ManagedModel) async {
        guard (try? BardoModelStore.live()) != nil else { return }
        switch model {
        case .whisperTurbo:
            let service = try? WhisperTranscriptionService.live()
            setState(await service?.hasInstalledModel() == true ? .installed : .notInstalled, for: model)
        case .speakerKit:
            let service = try? SpeakerDiarizationService.live()
            setState(await service?.hasInstalledModels() == true ? .installed : .notInstalled, for: model)
        case .meetingMinutes:
            setState(MeetingMinutesModelResourceResolver.isInstalled() ? .installed : .notInstalled, for: model)
        }
    }

    private func setState(_ state: ManagedModelState, for model: ManagedModel) {
        guard let index = rows.firstIndex(where: { $0.id == model }) else {
            rows.append(makeRow(for: model, state: state))
            return
        }
        rows[index].state = state
    }

    private func makeRow(for model: ManagedModel, state: ManagedModelState) -> ModelSettingsRowState {
        switch model {
        case .whisperTurbo:
            return ModelSettingsRowState(id: model, title: String(localized: "WhisperKit large-v3 Turbo"), detail: String(localized: "Downloaded during first-run setup with word timestamps"), supportsInstallation: true, state: state)
        case .speakerKit:
            return ModelSettingsRowState(id: model, title: String(localized: "SpeakerKit / Pyannote"), detail: String(localized: "Downloaded during first-run setup for speaker identification"), supportsInstallation: true, state: state)
        case .meetingMinutes:
            return ModelSettingsRowState(id: model, title: String(localized: "Meeting Minutes"), detail: String(localized: "Downloaded during first-run setup for on-device generation."), supportsInstallation: true, state: state)
        }
    }

    private nonisolated static func runtimeDownloadState(for fraction: Double) -> ManagedModelState {
        .downloading(min(1, max(0, fraction)))
    }

    private nonisolated static func transcriptionState(for snapshot: TranscriptionSetupProgressSnapshot) -> ManagedModelState {
        let value = min(1, max(0, snapshot.fractionCompleted))
        switch snapshot.stage {
        case .checking, .optimizingForMac:
            return .preparing(value)
        case .downloading:
            return .downloading(value)
        }
    }

    private nonisolated static func meetingMinutesState(for fraction: Double) -> ManagedModelState {
        let value = min(1, max(0, fraction))
        return value < 1 ? .downloading(value) : .preparing(1)
    }

    private nonisolated static func diarizationState(for snapshot: DiarizationSetupProgressSnapshot) -> ManagedModelState {
        let value = min(1, max(0, snapshot.fractionCompleted))
        switch snapshot.stage {
        case .checking, .optimizingForMac:
            return .preparing(value)
        case .downloading:
            return .downloading(value)
        }
    }
}
