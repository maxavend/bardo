import AppKit
import SwiftUI

struct SettingsView: View {
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
                Text("Bardo uses only models stored in its private folder.")
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
        .scenePadding()
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 720, minHeight: 480, idealHeight: 560, maxHeight: 680)
        .task {
            await model.refreshIfNeeded()
        }
        .alert(item: $pendingReset) { request in
            let message = request.reinstall
                ? String(localized: "Bardo will remove this model’s private files and start a fresh download.")
                : String(localized: "This frees space on your Mac. You can download the model again whenever you need it.")
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
            HStack(spacing: 12) {
                Image(systemName: row.symbol)
                    .frame(width: 22)
                    .foregroundStyle(row.stateColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.body.weight(.medium))
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    if !row.stateLabel.isEmpty {
                        Text(row.stateLabel)
                            .font(.callout)
                            .foregroundStyle(row.stateColor)
                            .lineLimit(1)
                    }
                    stateControl
                }
            }

            if let progress = row.progressFraction {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .padding(.leading, 34)
            }

            if case .failed(let message) = row.state {
                Text(String.localizedStringWithFormat(String(localized: "Failed: %@"), message))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.leading, 34)
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
            Button("Install") { action(.install) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .cancel:
            Button("Cancel") { action(.cancel) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .retry:
            Button("Retry") { action(.retry) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .reset, .resetAndInstall:
            Menu {
                Button("Show in Finder") { action(.reveal) }
                Divider()
                Button("Remove and Download Again", role: .destructive) { action(.resetAndInstall) }
                Button("Remove Model", role: .destructive) { action(.reset) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .accessibilityLabel(String.localizedStringWithFormat(String(localized: "More actions for %@"), row.title))
            .help("Show more actions")
        case .reveal:
            EmptyView()
        case .unavailable:
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
            return supportsInstallation ? "" : String(localized: "Available on demand")
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
        do {
            try BardoModelStore.live().reset(model)
            setState(.notInstalled, for: model)
        } catch {
            setState(.failed(error.localizedDescription), for: model)
        }
    }

    func resetAndInstall(_ model: ManagedModel) {
        do {
            try BardoModelStore.live().reset(model)
            setState(.notInstalled, for: model)
            install(model)
        } catch {
            setState(.failed(error.localizedDescription), for: model)
        }
    }

    func revealModelsFolder() {
        guard let store = try? BardoModelStore.live() else { return }
        let root = store.root(for: .qwen).deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func revealModelFolder(_ model: ManagedModel) {
        guard let store = try? BardoModelStore.live() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.root(for: model)])
    }

    private func runInstall(_ model: ManagedModel) async {
        defer { operationTasks[model] = nil }

        do {
            let store = try BardoModelStore.live()
            switch model {
            case .whisperBalanced, .whisperMaximumAccuracy:
                guard let definition = TranscriptionModelManager.catalog.first(where: {
                    managedModel(for: $0) == model
                }) else { return }
                let manager = TranscriptionModelManager(
                    definition: definition,
                    downloadRoot: store.root(for: model)
                )
                _ = try await manager.ensureResourcesAvailable { fraction in
                    let state = Self.whisperState(for: fraction)
                    Task { @MainActor [weak self] in
                        self?.setState(state, for: model)
                    }
                }
            case .parakeet:
                let service = try ParakeetTranscriptionService.live()
                _ = try await service.prepareForUse { snapshot in
                    let state = Self.transcriptionState(for: snapshot)
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
            case .qwen:
                return
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

        let store: BardoModelStore
        do {
            store = try BardoModelStore.live()
        } catch {
            rows = ManagedModel.allCases.map {
                makeRow(for: $0, state: .failed(error.localizedDescription))
            }
            return
        }
        for definition in TranscriptionModelManager.catalog {
            let model = managedModel(for: definition)
            guard operationTasks[model] == nil else { continue }
            let manager = TranscriptionModelManager(
                definition: definition,
                downloadRoot: store.root(for: model)
            )
            do {
                let installed = try await manager.hasInstalledModel()
                setState(installed ? .installed : .notInstalled, for: model)
            } catch {
                setState(.failed(error.localizedDescription), for: model)
            }
        }

        if operationTasks[.parakeet] == nil {
            do {
                let parakeet = try ParakeetTranscriptionService.live()
                let installed = await parakeet.hasInstalledModel()
                setState(installed ? .installed : .notInstalled, for: .parakeet)
            } catch {
                setState(.failed(error.localizedDescription), for: .parakeet)
            }
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

        let qwenInstalled = QwenMeetingMinutesModel.isInstalled(at: store.root(for: .qwen))
        setState(qwenInstalled ? .installed : .notInstalled, for: .qwen)
    }

    private func refreshModel(_ model: ManagedModel) async {
        guard let store = try? BardoModelStore.live() else { return }
        switch model {
        case .whisperBalanced, .whisperMaximumAccuracy:
            guard let definition = TranscriptionModelManager.catalog.first(where: {
                managedModel(for: $0) == model
            }) else { return }
            let manager = TranscriptionModelManager(
                definition: definition,
                downloadRoot: store.root(for: model)
            )
            setState((try? await manager.hasInstalledModel()) == true ? .installed : .notInstalled, for: model)
        case .parakeet:
            let service = try? ParakeetTranscriptionService.live()
            setState(await service?.hasInstalledModel() == true ? .installed : .notInstalled, for: model)
        case .speakerKit:
            let service = try? SpeakerDiarizationService.live()
            setState(await service?.hasInstalledModels() == true ? .installed : .notInstalled, for: model)
        case .qwen:
            setState(QwenMeetingMinutesModel.isInstalled(at: store.root(for: .qwen)) ? .installed : .notInstalled, for: model)
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
        case .whisperBalanced:
            return ModelSettingsRowState(id: model, title: String(localized: "WhisperKit large-v3 Turbo"), detail: String(localized: "Recommended for most transcriptions"), supportsInstallation: true, state: state)
        case .whisperMaximumAccuracy:
            return ModelSettingsRowState(id: model, title: String(localized: "WhisperKit large-v3"), detail: String(localized: "Higher accuracy, with higher resource usage"), supportsInstallation: true, state: state)
        case .parakeet:
            return ModelSettingsRowState(id: model, title: String(localized: "Parakeet TDT 0.6B v3"), detail: String(localized: "Fast and efficient on-device transcription"), supportsInstallation: true, state: state)
        case .speakerKit:
            return ModelSettingsRowState(id: model, title: String(localized: "SpeakerKit / Pyannote"), detail: String(localized: "Identifies speakers and creates voice samples"), supportsInstallation: true, state: state)
        case .qwen:
            return ModelSettingsRowState(id: model, title: String(localized: "Qwen 3.5 0.8B MLX 4-bit"), detail: String(localized: "Generates meeting minutes from your transcripts. Downloads automatically when needed."), supportsInstallation: false, state: state)
        }
    }

    private func managedModel(for definition: TranscriptionModelDefinition) -> ManagedModel {
        definition.id == TranscriptionModelManager.maximumAccuracyModelID ? .whisperMaximumAccuracy : .whisperBalanced
    }

    private nonisolated static func whisperState(for fraction: Double) -> ManagedModelState {
        let value = min(1, max(0, fraction))
        return value < 0.9 ? .downloading(value / 0.9) : .preparing((value - 0.9) / 0.1)
    }

    private nonisolated static func transcriptionState(for snapshot: TranscriptionSetupProgressSnapshot) -> ManagedModelState {
        let value = min(1, max(0, snapshot.fractionCompleted))
        switch snapshot.stage {
        case .checking, .preparingLanguageSupport, .optimizingForMac:
            return .preparing(value)
        case .downloading:
            return .downloading(value)
        }
    }

    private nonisolated static func diarizationState(for snapshot: DiarizationSetupProgressSnapshot) -> ManagedModelState {
        let value = min(1, max(0, snapshot.fractionCompleted))
        switch snapshot.stage {
        case .downloading:
            return .downloading(value)
        case .optimizingForMac:
            return .preparing(value)
        }
    }
}
