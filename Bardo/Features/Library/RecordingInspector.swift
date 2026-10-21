import Foundation
import SwiftUI

struct RecordingInspector: View {
    let recording: Recording
    let transcript: Transcript?
    var isCompressing = false
    /// Compresses the audio at a lower quality; `nil` where it cannot be offered.
    var compress: ((AudioQualityPreset) -> Void)?

    @State private var showsTechnicalDetails = false
    @State private var isConfirmingCompression = false

    var body: some View {
        Form {
            Section("Conversación") {
                LabeledContent("Creada") {
                    Text(recording.createdAt, format: Self.dateFormat)
                }
                if let modifiedAt {
                    LabeledContent("Modificada") {
                        Text(modifiedAt, format: Self.dateFormat)
                    }
                }
                LabeledContent("Duración", value: LibraryFormatting.duration(recording.duration))
                LabeledContent("Origen", value: LibraryFormatting.source(recording.sources))
                LabeledContent("Estado", value: LibraryFormatting.state(recording.processingState))
            }

            // How much space it takes, and compressing it, right after what it is.
            if !recording.audioAssets.isEmpty {
                Section("Archivo") {
                    if recording.audioAssets.count == 1, let asset = recording.audioAssets.first {
                        LabeledContent("Nombre", value: asset.originalFileName)
                        if let size = formattedFileSize(for: asset) {
                            LabeledContent("Tamaño", value: size)
                        }
                    } else {
                        LabeledContent(
                            "Pistas de audio",
                            value: "\(recording.audioAssets.count)"
                        )
                        if let size = formattedTotalFileSize {
                            LabeledContent("Tamaño total", value: size)
                        }
                    }
                    if compress != nil {
                        compressionRow
                    }
                }
            }

            if let transcript, transcript.recordingID == recording.id {
                Section("Contenido") {
                    LabeledContent("Idioma", value: LibraryFormatting.language(transcript.languageCode))
                    if transcript.diarizationMetadata != nil {
                        LabeledContent("Participantes", value: "\(transcript.speakers.count)")
                    }
                }

                if transcript.metadata.processingDuration != nil
                    || transcript.diarizationMetadata?.processingDuration != nil {
                    Section("Procesamiento") {
                        if let duration = transcript.metadata.processingDuration {
                            LabeledContent(
                                "Transcripción",
                                value: LibraryFormatting.processingDuration(duration)
                            )
                        }
                        if let duration = transcript.diarizationMetadata?.processingDuration {
                            LabeledContent(
                                "Hablantes",
                                value: LibraryFormatting.processingDuration(duration)
                            )
                        }
                    }
                }
            }

            if !recording.audioAssets.isEmpty {
                Section {
                    DisclosureGroup("Detalles técnicos", isExpanded: $showsTechnicalDetails) {
                        ForEach(Array(recording.audioAssets.enumerated()), id: \.element.id) { index, asset in
                            VStack(alignment: .leading, spacing: 6) {
                                if recording.audioAssets.count > 1 {
                                    Text("Pista \(index + 1)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                LabeledContent("Formato", value: asset.fileExtension.uppercased())
                                LabeledContent("Códec", value: asset.metadata.codec)
                                LabeledContent("Muestreo", value: LibraryFormatting.sampleRate(asset.metadata.sampleRate))
                                LabeledContent("Canales", value: "\(asset.metadata.channelCount)")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Compression

    private var compressionRow: some View {
        let options = compressionOptions
        return LabeledContent {
            if isCompressing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Comprimir…") { isConfirmingCompression = true }
                    .disabled(options.isEmpty)
            }
        } label: {
            Text("Comprimir audio")
            Text(isCompressing
                ? "Comprimiendo…"
                : (options.last.map { "Puede ocupar unos \(SettingsView.megabytes($0.bytes))." } ?? "Ya ocupa poco espacio."))
        }
        .confirmationDialog(
            "¿Seguro que quieres comprimir el audio?",
            isPresented: $isConfirmingCompression,
            titleVisibility: .visible
        ) {
            ForEach(options, id: \.preset) { option in
                Button("\(option.preset.title) · unos \(SettingsView.megabytes(option.bytes))") {
                    compress?(option.preset)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("\(formattedTotalBytes.map { "Ahora ocupa \($0). " } ?? "")Se seguirá entendiendo y transcribiendo todo, pero la calidad original no se puede recuperar.")
        }
    }

    /// The qualities that would save a real share of the space, with what each would take.
    private var compressionOptions: [(preset: AudioQualityPreset, bytes: Double)] {
        guard let current = totalByteCount else { return [] }
        return [AudioQualityPreset.high, .balanced, .compact].compactMap { preset in
            let encoding = AudioEncoding(preset: preset, format: .aac)
            let bytes = recording.audioAssets.reduce(0.0) { total, asset in
                total + encoding.bytesPerMinute(channels: Int(asset.metadata.channelCount)) * asset.metadata.duration / 60
            }
            return bytes < Double(current) * 0.8 ? (preset, bytes) : nil
        }
    }

    private var totalByteCount: Int64? {
        let sizes = recording.audioAssets.compactMap(byteCount(for:))
        return sizes.count == recording.audioAssets.count ? sizes.reduce(0, +) : nil
    }

    private var formattedTotalBytes: String? {
        totalByteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private static let dateFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).year().hour().minute()

    private var recordingDirectory: URL? {
        guard let root = try? RecordingStore.defaultLibraryURL() else { return nil }
        return root.appendingPathComponent(recording.id.uuidString, isDirectory: true)
    }

    private var modifiedAt: Date? {
        guard let directory = recordingDirectory else { return nil }
        let manifest = directory.appendingPathComponent(RecordingStore.manifestFileName)
        return try? manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func fileURL(for asset: AudioAsset) -> URL? {
        recordingDirectory?
            .appendingPathComponent(RecordingStore.audioDirectoryName, isDirectory: true)
            .appendingPathComponent("\(asset.id.uuidString).\(asset.fileExtension)")
    }

    private func byteCount(for asset: AudioAsset) -> Int64? {
        guard let url = fileURL(for: asset),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else {
            return nil
        }
        return Int64(size)
    }

    private func formattedFileSize(for asset: AudioAsset) -> String? {
        guard let bytes = byteCount(for: asset) else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var formattedTotalFileSize: String? {
        let sizes = recording.audioAssets.compactMap(byteCount(for:))
        guard sizes.count == recording.audioAssets.count else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
    }
}
