import SwiftUI

struct RecordingInspector: View {
    let recording: Recording
    let transcript: Transcript?

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Created") {
                    Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                LabeledContent("Duration", value: LibraryFormatting.duration(recording.duration))
                LabeledContent("Source", value: LibraryFormatting.source(recording.sources))
                LabeledContent("Status", value: LibraryFormatting.state(recording.processingState))
            }

            if !recording.audioAssets.isEmpty {
                ForEach(Array(recording.audioAssets.enumerated()), id: \.element.id) { index, asset in
                    Section(recording.audioAssets.count == 1 ? "Audio" : "Audio Track \(index + 1)") {
                        LabeledContent("File", value: asset.originalFileName)
                        LabeledContent("Codec", value: asset.metadata.codec)
                        LabeledContent("Sample Rate", value: LibraryFormatting.sampleRate(asset.metadata.sampleRate))
                        LabeledContent("Channels", value: String(asset.metadata.channelCount))
                        if recording.audioAssets.count > 1 {
                            LabeledContent("Role", value: roleText(asset.role))
                        }
                    }
                }
            }

            if let transcript, transcript.recordingID == recording.id {
                Section("Transcript") {
                    LabeledContent("Language", value: LibraryFormatting.language(transcript.languageCode))
                    LabeledContent("Engine", value: "\(transcript.metadata.engine) \(transcript.metadata.engineVersion)")
                    LabeledContent("Model", value: transcript.metadata.modelID)
                    LabeledContent("Created") {
                        Text(transcript.metadata.createdAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }

                if let diarization = transcript.diarizationMetadata {
                    Section("Speakers") {
                        LabeledContent("Detected", value: String(transcript.speakers.count))
                        LabeledContent("Engine", value: "\(diarization.engine) \(diarization.engineVersion)")
                        LabeledContent("Model", value: diarization.modelID)
                    }
                }
            }

            Section("Advanced") {
                LabeledContent("Recording ID") {
                    Text(recording.id.uuidString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
    }

    private func roleText(_ role: AudioAssetRole) -> String {
        switch role {
        case .importedOriginal: "Imported Original"
        case .microphoneOriginal: "Microphone Original"
        case .systemOriginal: "System Original"
        case .conversationMix: "Conversation Mix"
        }
    }
}
