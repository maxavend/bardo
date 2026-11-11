import SwiftUI

/// Compresses one or several conversations: choose a quality, hear an excerpt as it is
/// and as it would sound, see what it would take, then compress.
struct CompressAudioSheet: View {
    let recordingIDs: [Recording.ID]
    @ObservedObject var model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = CompressionPreviewPlayer()
    @State private var preset: AudioQualityPreset = .balanced
    @State private var report: LibraryStorageReport?
    @State private var previewRecordingID: Recording.ID?
    /// Whether this sheet started the compression on screen.
    @State private var hasStarted = false

    static let presets: [AudioQualityPreset] = [.high, .balanced, .compact]

    var body: some View {
        VStack(spacing: 0) {
            header

            if hasStarted, let run = model.compressionRun {
                // Only as tall as its progress or result: nothing left to choose.
                CompressionProgressView(run: run, stop: model.stopCompression)
            } else {
                form
                    .frame(maxHeight: .infinity)
            }

            footer
        }
        .frame(width: 520)
        .frame(minHeight: hasStarted ? nil : 420, idealHeight: hasStarted ? nil : 540)
        .interactiveDismissDisabled(model.compressionRun?.isRunning == true)
        .task {
            model.clearCompressionRun()
            report = await model.storageReport(for: Set(recordingIDs))
            preset = Self.recommendedPreset(for: recordings, report: report)
            previewRecordingID = recordings.first { plan(for: preset).shrinkingRecordingIDs.contains($0.id) }?.id
                ?? recordings.first?.id
        }
        .onChange(of: previewRecordingID) { _, _ in preparePreview() }
        .onChange(of: preset) { _, _ in preparePreview() }
        .onDisappear {
            preview.stop()
            if model.compressionRun?.isRunning != true { model.clearCompressionRun() }
        }
        #if DEBUG
        .onDesignReviewCommand { step in
            switch step.action {
            case "compressPreset":
                if let value = AudioQualityPreset(rawValue: step.value) { preset = value }
            case "compressStart":
                compress()
            default:
                break
            }
        }
        #endif
    }

    // MARK: Layout

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Comprimir audio")
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    private var form: some View {
        Form {
            Section {
                Picker("Calidad", selection: $preset) {
                    ForEach(Self.presets) { option in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.title)
                            Text(caption(for: option))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("Calidad")
            } footer: {
                Text(qualityFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if recordings.count > 1 {
                    Picker("Escuchar", selection: $previewRecordingID) {
                        ForEach(recordings) { recording in
                            Text(LibraryFormatting.recordingTitle(recording))
                                .tag(Optional(recording.id))
                        }
                    }
                }
                previewControls
            } header: {
                Text("Vista previa")
            } footer: {
                Text("20 segundos de la conversación. Cambia de versión mientras suena para compararlas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .monospacedDigit()
    }

    @ViewBuilder
    private var previewControls: some View {
        switch preview.state {
        case .unavailable:
            Label("No se puede escuchar esta conversación.", systemImage: "speaker.slash")
                .foregroundStyle(.secondary)
        default:
            HStack(spacing: 12) {
                Button {
                    model.playback.pause()
                    preview.togglePlayback()
                } label: {
                    Label(preview.isPlaying ? "Pausar" : "Reproducir", systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 16)
                }
                .disabled(preview.state != .ready)
                .help(preview.isPlaying ? "Pausar" : "Reproducir")

                Picker("Versión", selection: $preview.version) {
                    Text("Original").tag(CompressionPreviewPlayer.Version.original)
                    Text("Comprimido").tag(CompressionPreviewPlayer.Version.compressed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 8)

                if preview.state == .preparing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparando…")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(LibraryFormatting.duration(preview.position)) / \(LibraryFormatting.duration(preview.duration))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// What compressing frees, beside the button that does it.
    @ViewBuilder
    private var sizeSummary: some View {
        if let plan = currentPlan {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.savesSpace ? "Libera unos \(LibraryStorage.format(plan.savedBytes))" : "No libera espacio")
                    .font(.headline)
                    .foregroundStyle(plan.savesSpace ? .primary : .secondary)
                Text(plan.savesSpace
                    ? "De \(LibraryStorage.format(plan.currentBytes)) a unos \(LibraryStorage.format(plan.estimatedBytes))"
                    : "Ocupa \(LibraryStorage.format(plan.currentBytes)); con esta calidad no ocuparía menos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if hasStarted, let run = model.compressionRun {
                Spacer()
                if !run.isRunning {
                    Button("Listo") { dismiss() }
                        .bardoPrimaryAction()
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                sizeSummary
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Comprimir", action: compress)
                    .bardoPrimaryAction()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(currentPlan?.savesSpace != true || model.compressionRun?.isRunning == true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: Content

    private var recordings: [Recording] {
        recordingIDs.compactMap { id in model.recordings.first { $0.id == id } }
    }

    private var subtitle: String {
        if recordings.count == 1, let recording = recordings.first {
            return LibraryFormatting.recordingTitle(recording)
        }
        return "\(recordings.count) conversaciones"
    }

    private func plan(for preset: AudioQualityPreset) -> AudioCompressionPlan {
        AudioCompressionPlan(recordings: recordings, audioBytes: report?.allAudioBytes ?? [:], preset: preset)
    }

    private var currentPlan: AudioCompressionPlan? {
        report == nil ? nil : plan(for: preset)
    }

    private func caption(for option: AudioQualityPreset) -> String {
        guard report != nil else { return option.detail }
        let plan = plan(for: option)
        return plan.savesSpace
            ? "\(option.detail) Unos \(LibraryStorage.format(plan.estimatedBytes))."
            : "\(option.detail) No ocuparía menos."
    }

    private var qualityFooter: String {
        let kept = recordings.count > 1
            ? " Las que ya ocupan poco quedan como están."
            : ""
        return "Con cualquiera se entiende y se transcribe todo. La calidad original no se puede recuperar.\(kept)"
    }

    /// Equilibrada, unless it would save nothing and a smaller quality would.
    static func recommendedPreset(for recordings: [Recording], report: LibraryStorageReport?) -> AudioQualityPreset {
        let bytes = report?.allAudioBytes ?? [:]
        for preset in [AudioQualityPreset.balanced, .compact] {
            if AudioCompressionPlan(recordings: recordings, audioBytes: bytes, preset: preset).savesSpace {
                return preset
            }
        }
        return .balanced
    }

    private func preparePreview() {
        guard let id = previewRecordingID,
              let recording = recordings.first(where: { $0.id == id }),
              let asset = recording.audioAssets.min(by: { $0.role.playbackPriority < $1.role.playbackPriority })
        else { return }
        let preset = preset
        Task {
            guard let url = try? await model.managedAudioURL(for: asset, in: id) else { return }
            preview.prepare(source: url, duration: asset.metadata.duration, preset: preset)
        }
    }

    private func compress() {
        guard currentPlan?.savesSpace == true else { return }
        preview.stop()
        hasStarted = true
        let ids = recordingIDs
        let preset = preset
        Task { await model.compressAudio(ids, to: preset) }
    }
}

/// The compression while it runs, and what it achieved once it ends.
private struct CompressionProgressView: View {
    let run: AudioCompressionRun
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if run.isRunning {
                ProgressView(value: run.total > 1 ? run.fractionCompleted : nil) {
                    Text(run.total > 1 ? "Comprimiendo \(min(run.completed + 1, run.total)) de \(run.total)…" : "Comprimiendo…")
                } currentValueLabel: {
                    if let title = run.currentTitle {
                        Text(title)
                            .lineLimit(1)
                    }
                }
                if run.total > 1 {
                    Button("Detener", action: stop)
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resultTitle)
                            .font(.headline)
                        if let detail = resultDetail {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } icon: {
                    Image(systemName: run.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(run.failures.isEmpty ? .green : .orange)
                        .font(.title2)
                }

                if !run.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(run.failures.enumerated()), id: \.offset) { _, failure in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(failure.title)
                                Text(failure.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 34)
                }
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private var resultTitle: String {
        if run.savedBytes > 0 {
            return "Se liberaron \(LibraryStorage.format(run.savedBytes))"
        }
        return run.failures.isEmpty ? "El audio ya ocupaba poco" : "No se pudo comprimir"
    }

    private var resultDetail: String? {
        if run.wasStopped {
            return "Se detuvo con \(run.completed) de \(run.total) conversaciones revisadas."
        }
        if run.savedBytes == 0 && run.failures.isEmpty {
            return "Quedó como estaba."
        }
        return nil
    }
}
