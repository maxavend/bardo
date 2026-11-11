import Foundation
import SwiftUI

struct RecordingInspector: View {
    let recording: Recording
    let transcript: Transcript?
    var isCompressing = false
    /// Opens the compression sheet; `nil` where it cannot be offered.
    var compress: (() -> Void)?

    @State private var showsTechnicalDetails = false

    var body: some View {
        ScrollViewReader { proxy in
            form
            #if DEBUG
            .onDesignReviewCommand { step in
                guard step.action == "details" else { return }
                showsTechnicalDetails = true
                Task {
                    try? await Task.sleep(for: .seconds(0.3))
                    proxy.scrollTo(Self.technicalDetailsID, anchor: .bottom)
                }
            }
            #endif
        }
    }

    private static let technicalDetailsID = "technicalDetails"

    private var form: some View {
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
            }

            if processing != nil || !recording.audioAssets.isEmpty {
                Section {
                    DisclosureGroup("Detalles técnicos", isExpanded: $showsTechnicalDetails) {
                        if let processing {
                            VStack(alignment: .leading, spacing: 6) {
                                detailHeading("Procesamiento")
                                if let model = processing.model {
                                    LabeledContent("Modelo", value: model)
                                }
                                if let duration = processing.transcription {
                                    LabeledContent(
                                        "Transcripción",
                                        value: LibraryFormatting.processingDuration(duration)
                                    )
                                }
                                if let duration = processing.speakers {
                                    LabeledContent(
                                        "Hablantes",
                                        value: LibraryFormatting.processingDuration(duration)
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        ForEach(Array(recording.audioAssets.enumerated()), id: \.element.id) { index, asset in
                            VStack(alignment: .leading, spacing: 6) {
                                if recording.audioAssets.count > 1 {
                                    detailHeading("Pista \(index + 1)")
                                } else if processing != nil {
                                    detailHeading("Audio")
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
                .id(Self.technicalDetailsID)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Technical details

    /// How the transcript was made: the model and how long each step took.
    private var processing: (model: String?, transcription: TimeInterval?, speakers: TimeInterval?)? {
        guard let transcript, transcript.recordingID == recording.id else { return nil }
        let model = LibraryFormatting.transcriptionModel(transcript.metadata)
        let transcription = transcript.metadata.processingDuration
        let speakers = transcript.diarizationMetadata?.processingDuration
        guard model != nil || transcription != nil || speakers != nil else { return nil }
        return (model, transcription, speakers)
    }

    private func detailHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Compression

    private var compressionRow: some View {
        LabeledContent {
            if isCompressing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Comprimir…") { compress?() }
            }
        } label: {
            Text("Comprimir audio")
            Text(isCompressing ? "Comprimiendo…" : compressionHint)
        }
    }

    /// What Equilibrada would leave, as a hint before opening the sheet.
    private var compressionHint: String {
        let sizes = Dictionary(uniqueKeysWithValues: recording.audioAssets.compactMap { asset in
            byteCount(for: asset).map { (asset.id, $0) }
        })
        let plan = AudioCompressionPlan(recordings: [recording], audioBytes: sizes, preset: .balanced)
        return plan.savesSpace
            ? "Puede ocupar unos \(LibraryStorage.format(plan.estimatedBytes))."
            : "Ya ocupa poco espacio."
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
