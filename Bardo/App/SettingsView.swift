import AppKit
import SwiftUI

struct SettingsView: View {
    @StateObject private var model = ModelSettingsViewModel()

    var body: some View {
        Form {
            Section {
                Text("Bardo keeps recordings, transcripts, speaker names, and AI models on this Mac. Nothing in this screen uploads audio.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label("Privacy", systemImage: "lock.shield")
            }

            Section {
                ForEach(model.rows) { row in
                    ModelSettingsRow(row: row)
                }
            } header: {
                HStack {
                    Label("Local Models", systemImage: "cpu")
                    Spacer()
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Refresh") {
                        model.refresh()
                    }
                    .buttonStyle(.link)
                }
            } footer: {
                Text("Installed means Bardo found a complete model in its private model folder. Other applications’ caches are not used for this status.")
            }

            Section {
                Button {
                    model.revealModelsFolder()
                } label: {
                    Label("Show Model Folder in Finder", systemImage: "folder")
                }
            } header: {
                Label("Storage", systemImage: "externaldrive")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .padding(20)
        .task {
            await model.refreshIfNeeded()
        }
    }
}

private struct ModelSettingsRow: View {
    let row: ModelSettingsRowState

    var body: some View {
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
            Text(row.stateLabel)
                .font(.callout)
                .foregroundStyle(row.stateColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.stateLabel). \(row.detail)")
    }
}

struct ModelSettingsRowState: Identifiable, Equatable, Sendable {
    let id: ManagedModel
    let title: String
    let detail: String
    let state: ManagedModelState

    var stateLabel: String {
        switch state {
        case .notInstalled:
            return "Not Installed"
        case .downloading(let fraction):
            return "Downloading \(percentage(fraction))"
        case .preparing(let fraction):
            return "Preparing \(percentage(fraction))"
        case .installed:
            return "Installed"
        case .failed:
            return "Failed"
        }
    }

    var symbol: String {
        switch state {
        case .notInstalled: return "circle"
        case .downloading: return "arrow.down.circle"
        case .preparing: return "gearshape"
        case .installed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    var stateColor: Color {
        switch state {
        case .notInstalled: return .secondary
        case .downloading, .preparing: return .accentColor
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

    deinit {
        refreshTask?.cancel()
    }

    func refreshIfNeeded() async {
        guard !didRefresh else { return }
        await refreshAsync()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.refreshAsync()
        }
    }

    func revealModelsFolder() {
        guard let store = try? BardoModelStore.live() else { return }
        let root = store.root(for: .qwen).deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    private func refreshAsync() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            didRefresh = true
            refreshTask = nil
        }

        guard let store = try? BardoModelStore.live() else { return }

        var nextRows: [ModelSettingsRowState] = []
        for definition in TranscriptionModelManager.catalog {
            let managedModel: ManagedModel = definition.id == TranscriptionModelManager.maximumAccuracyModelID
                ? .whisperMaximumAccuracy
                : .whisperBalanced
            let manager = TranscriptionModelManager(
                definition: definition,
                downloadRoot: store.root(for: managedModel)
            )
            let installed = (try? await manager.hasInstalledModel()) == true
            nextRows.append(
                ModelSettingsRowState(
                    id: managedModel,
                    title: definition.displayName,
                    detail: definition.isDefault ? "Recommended for everyday transcription" : "Highest WhisperKit accuracy tier",
                    state: installed ? .installed : .notInstalled
                )
            )
        }

        if let parakeet = try? ParakeetTranscriptionService.live() {
            let installed = await parakeet.hasInstalledModel()
            nextRows.append(
                ModelSettingsRowState(
                    id: .parakeet,
                    title: "Parakeet TDT 0.6B v3",
                    detail: "Instant transcription with FluidAudio",
                    state: installed ? .installed : .notInstalled
                )
            )
        }

        if let speakers = try? SpeakerDiarizationService.live() {
            let installed = await speakers.hasInstalledModels()
            nextRows.append(
                ModelSettingsRowState(
                    id: .speakerKit,
                    title: "SpeakerKit / Pyannote",
                    detail: "Local speaker identification and voice previews",
                    state: installed ? .installed : .notInstalled
                )
            )
        }

        let qwenInstalled = QwenMeetingMinutesModel.isInstalled(at: store.root(for: .qwen))
        nextRows.append(
            ModelSettingsRowState(
                id: .qwen,
                title: "Qwen 3.5 0.8B MLX 4-bit",
                detail: "Meeting minutes only; never used for audio transcription",
                state: qwenInstalled ? .installed : .notInstalled
            )
        )

        rows = nextRows
    }
}
