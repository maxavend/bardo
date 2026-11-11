import AppKit
import SwiftUI

/// Compares an excerpt and the estimated size before compressing one or more recordings.
struct CompressAudioSheet: View {
    let recordingIDs: [Recording.ID]
    @ObservedObject var model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = CompressionPreviewPlayer()
    @State private var format: AudioCompressionEncoding.Format = .aac
    @State private var bitRate: AudioCompressionEncoding.BitRate = .kbps24
    @State private var channels: AudioCompressionEncoding.Channels = .mono
    @State private var savesCopy = false
    @State private var mergeTracks = false
    @State private var choosingFolder = false
    @State private var report: LibraryStorageReport?
    @State private var previewRecordingID: Recording.ID?
    /// Whether this sheet started the compression on screen.
    @State private var hasStarted = false

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
        .frame(minHeight: hasStarted ? nil : 390, idealHeight: hasStarted ? nil : formHeight)
        .interactiveDismissDisabled(choosingFolder || model.compressionRun?.isRunning == true)
        .task {
            model.clearCompressionRun()
            mergeTracks = canMergeTracks
            if hasStereoTracks { channels = .stereo }
            if AudioCompressionTranscoder.ffmpegURL == nil { bitRate = .kbps48 }
            report = await model.storageReport(for: Set(recordingIDs))
            let preferredIDs = currentPlan?.shrinkingRecordingIDs ?? []
            previewRecordingID = recordings.first { preferredIDs.contains($0.id) }?.id
                ?? recordings.first?.id
        }
        .onChange(of: previewRecordingID) { _, _ in preparePreview() }
        .onChange(of: encoding) { _, _ in preparePreview() }
        .onChange(of: mergeTracks) { _, _ in preparePreview() }
        .onDisappear {
            preview.stop()
            if model.compressionRun?.isRunning != true { model.clearCompressionRun() }
        }
        #if DEBUG
        .onDesignReviewCommand { step in
            switch step.action {
            case "compressFormat":
                if let value = AudioCompressionEncoding.Format(rawValue: step.value) { format = value }
            case "compressBitRate":
                if let rate = Int(step.value), let value = AudioCompressionEncoding.BitRate(rawValue: rate) { bitRate = value }
            case "compressChannels":
                if let count = Int(step.value), let value = AudioCompressionEncoding.Channels(rawValue: count) { channels = value }
            case "compressMerge":
                mergeTracks = canMergeTracks
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
                Picker("Formato", selection: $format) {
                    ForEach(AudioCompressionEncoding.Format.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                Picker("Bitrate", selection: $bitRate) {
                    ForEach(AudioCompressionEncoding.BitRate.allCases, id: \.self) { option in
                        Text("\(option.rawValue) kbps").tag(option)
                    }
                }
                LabeledContent("Canales") {
                    Picker("Canales", selection: $channels) {
                        ForEach(AudioCompressionEncoding.Channels.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if canMergeTracks {
                    Toggle("Unir en una sola pista", isOn: $mergeTracks)
                        .toggleStyle(.switch)
                }
                Toggle("Guardar una copia", isOn: $savesCopy)
                    .toggleStyle(.switch)
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
                Text("Hasta 20 segundos de la conversación. Cambia de versión mientras suena para compararlas.")
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
        case .unavailable(let message):
            Label(message, systemImage: "speaker.slash")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Text(savesCopy
                    ? "Copia de unos \(LibraryStorage.format(plan.copyBytes))"
                    : plan.savesSpace ? "Libera unos \(LibraryStorage.format(plan.savedBytes))" : "No libera espacio")
                    .font(.headline)
                    .foregroundStyle(savesCopy || plan.savesSpace ? .primary : .secondary)
                Text(savesCopy ? "Original: \(LibraryStorage.format(plan.currentBytes))" : plan.savesSpace
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
                    if !run.copyURLs.isEmpty {
                        Button("Mostrar en Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(run.copyURLs)
                        }
                    }
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
                Button(compressionButtonTitle, action: compress)
                    .bardoPrimaryAction()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCompress)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: Content

    private var formHeight: CGFloat {
        (recordingIDs.count > 1 ? 520 : 475) + (canMergeTracks ? 48 : 0)
    }

    private var recordings: [Recording] {
        recordingIDs.compactMap { id in model.recordings.first { $0.id == id } }
    }

    private var subtitle: String {
        if recordings.count == 1, let recording = recordings.first {
            return LibraryFormatting.recordingTitle(recording)
        }
        return "\(recordings.count) conversaciones"
    }

    private var encoding: AudioCompressionEncoding {
        AudioCompressionEncoding(format: format, bitRate: bitRate, channels: channels)
    }

    private var encoderAvailable: Bool {
        if AudioCompressionTranscoder.ffmpegURL != nil { return true }
        guard !encoding.requiresFFmpeg else { return false }
        return !mergeTracks || !recordings.compactMap { AudioCompressionMix(recording: $0) }.contains {
            $0.existing == nil && ($0.originals.count > 1 || ($0.originals.first?.timelineOffset ?? 0) > 0)
        }
    }

    private var compressionButtonTitle: LocalizedStringKey {
        if savesCopy { return "Guardar copia…" }
        return mergeTracks ? "Unir y comprimir" : "Comprimir"
    }

    private var currentPlan: AudioCompressionPlan? {
        guard let report else { return nil }
        return AudioCompressionPlan(
            recordings: recordings, audioBytes: report.allAudioBytes, encoding: encoding, mergeTracks: mergeTracks
        )
    }

    private var canCompress: Bool {
        guard !choosingFolder, encoderAvailable, model.compressionRun?.isRunning != true,
              let plan = currentPlan else { return false }
        return savesCopy ? plan.copyBytes > 0 : plan.savesSpace
    }

    private var qualityFooter: String {
        guard encoderAvailable else {
            return AudioCompressionTranscoder.Failure.missingFFmpeg.localizedDescription
        }
        if mergeTracks {
            return savesCopy
                ? "Se guardará un archivo por conversación y se conservarán las pistas originales."
                : "La pista unificada reemplazará las pistas separadas si ahorra más del 20 %. Ya no podrás escucharlas por separado."
        }
        let action = savesCopy
            ? "Se guardará una copia de cada pista."
            : "Se reemplazan las pistas que ahorren más del 20 %. El cambio es permanente."
        if channels == .mono, hasStereoTracks {
            return "Las pistas estéreo se comprimirán en mono. \(action)"
        }
        return action
    }

    private var hasStereoTracks: Bool {
        recordings.contains { $0.audioAssets.contains { $0.metadata.channelCount > 1 } }
    }

    private var canMergeTracks: Bool {
        recordings.contains { AudioCompressionMix(recording: $0) != nil }
    }

    private func preparePreview() {
        guard encoderAvailable else {
            preview.stop()
            return
        }
        guard let id = previewRecordingID,
              let recording = recordings.first(where: { $0.id == id })
        else { return }
        let encoding = encoding
        let merge = mergeTracks
        Task {
            let input = try? await model.compressionPreviewInput(for: recording, mergeTracks: merge)
            guard encoding == self.encoding, merge == mergeTracks, id == previewRecordingID, !hasStarted else { return }
            if let input {
                preview.prepare(source: input, encoding: encoding)
            } else {
                preview.showUnavailable()
            }
        }
    }

    private func compress() {
        guard canCompress else { return }
        let copy = savesCopy
        let ids = recordingIDs
        let encoding = encoding
        let merge = mergeTracks
        choosingFolder = copy
        Task {
            let folder: URL?
            if copy {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Guardar aquí"
                panel.message = "Elige una carpeta para las copias de audio."
                let response = await panel.begin()
                choosingFolder = false
                guard response == .OK, let url = panel.url else { return }
                folder = url
            } else {
                folder = nil
            }
            preview.stop()
            hasStarted = true
            await model.compressAudio(ids, using: encoding, copyTo: folder, mergeTracks: merge)
        }
    }
}

/// The compression while it runs, and what it achieved once it ends.
private struct CompressionProgressView: View {
    let run: AudioCompressionRun
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if run.isRunning {
                runningProgress
                if run.total > 1 {
                    Button(
                        run.stoppingAfterCurrent ? "Se detendrá al terminar esta conversación" : "Detener después de esta conversación",
                        action: stop
                    )
                    .disabled(run.stoppingAfterCurrent)
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

    private var runningProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            if run.total > 1, let title = run.currentTitle {
                Text("Conversación \(min(run.completed + 1, run.total)) de \(run.total) · \(title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let fraction = track?.recordingFraction {
                ProgressView(value: fraction) {
                    HStack {
                        Text(phaseTitle)
                        Spacer()
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView(value: nil as Double?) { Text(phaseTitle) }
            }
            if let track {
                HStack(spacing: 12) {
                    Text("Pista \(track.number) de \(track.count) · \(track.title)")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if track.duration > 0 {
                        Text("\(LibraryFormatting.duration(track.processed)) / \(LibraryFormatting.duration(track.duration))")
                            .fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var track: AudioCompressionRun.TrackProgress? {
        guard case .encoding(let track) = run.phase else { return nil }
        return track
    }

    private var phaseTitle: LocalizedStringKey {
        switch run.phase {
        case .preparing: "Preparando pistas…"
        case .encoding: "Comprimiendo audio…"
        case .saving: "Guardando audio…"
        case .preparingPlayback: "Preparando la reproducción…"
        }
    }

    private var resultTitle: String {
        if !run.copyURLs.isEmpty {
            return "Copias guardadas · \(LibraryStorage.format(run.copiedBytes))"
        }
        if run.copyFolder != nil { return "No se guardaron copias" }
        if run.savedBytes > 0 {
            return "Se liberaron \(LibraryStorage.format(run.savedBytes))"
        }
        return run.failures.isEmpty ? "El audio ya ocupaba poco" : "No se pudo comprimir"
    }

    private var resultDetail: String? {
        if run.wasStopped {
            return "Se detuvo con \(run.completed) de \(run.total) conversaciones revisadas."
        }
        if run.copyFolder == nil && run.savedBytes == 0 && run.failures.isEmpty {
            return "Quedó como estaba."
        }
        return nil
    }
}
