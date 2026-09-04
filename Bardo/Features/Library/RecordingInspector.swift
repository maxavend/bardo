import Foundation
import SwiftUI

struct RecordingInspector: View {
    let recording: Recording
    let transcript: Transcript?
    let meetingMinutes: MeetingMinutes?

    @State private var showsTechnicalDetails = false

    var body: some View {
        Form {
            Section("Conversación") {
                LabeledContent("Creada") {
                    Text(recording.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                }
                if let modifiedAt {
                    LabeledContent("Última modificación") {
                        Text(modifiedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    }
                }
                LabeledContent("Duración", value: LibraryFormatting.duration(recording.duration))
                LabeledContent("Origen", value: LibraryFormatting.source(recording.sources))
                LabeledContent("Estado", value: LibraryFormatting.state(recording.processingState))
            }

            if let transcript, transcript.recordingID == recording.id {
                Section("Contenido") {
                    LabeledContent("Idioma", value: LibraryFormatting.language(transcript.languageCode))
                    if transcript.diarizationMetadata != nil {
                        LabeledContent(
                            "Participantes",
                            value: transcript.speakers.count == 1
                                ? "1 participante"
                                : "\(transcript.speakers.count) participantes"
                        )
                    }
                }

                if transcript.metadata.processingDuration != nil
                    || transcript.diarizationMetadata?.processingDuration != nil
                    || matchingMinutes?.processingDuration != nil {
                    Section("Tiempos de procesamiento") {
                        if let duration = transcript.metadata.processingDuration {
                            LabeledContent(
                                "Transcripción",
                                value: LibraryFormatting.processingDuration(duration)
                            )
                        }
                        if let duration = transcript.diarizationMetadata?.processingDuration {
                            LabeledContent(
                                "Identificación de hablantes",
                                value: LibraryFormatting.processingDuration(duration)
                            )
                        }
                        if let duration = matchingMinutes?.processingDuration {
                            LabeledContent(
                                "Minuta",
                                value: LibraryFormatting.processingDuration(duration)
                            )
                        }
                    }
                }
            }

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
                }

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

            Section("Privacidad") {
                Label(
                    "El audio, la transcripción y la minuta permanecen almacenados en este Mac.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var matchingMinutes: MeetingMinutes? {
        guard let meetingMinutes, meetingMinutes.recordingID == recording.id else { return nil }
        return meetingMinutes
    }

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

struct RecordingInformationSheet: View {
    let recording: Recording
    let transcript: Transcript?
    let meetingMinutes: MeetingMinutes?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Información")
                        .font(.headline)

                    Text(LibraryFormatting.recordingTitle(recording))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Listo") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            RecordingInspector(
                recording: recording,
                transcript: transcript,
                meetingMinutes: meetingMinutes
            )
        }
        .frame(width: 460, height: 600)
    }
}
