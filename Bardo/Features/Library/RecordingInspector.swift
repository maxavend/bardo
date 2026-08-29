import SwiftUI

struct RecordingInspector: View {
    let recording: Recording
    let transcript: Transcript?
    let canEditSpeakers: Bool
    let onRenameSpeaker: (Speaker.ID) -> Void

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
                    Section {
                        LabeledContent("File", value: asset.originalFileName)
                        LabeledContent("Codec", value: asset.metadata.codec)
                        LabeledContent("Sample Rate", value: LibraryFormatting.sampleRate(asset.metadata.sampleRate))
                        LabeledContent("Channels", value: String(asset.metadata.channelCount))
                        if recording.audioAssets.count > 1 {
                            LabeledContent("Role", value: roleText(asset.role))
                        }
                    } header: {
                        Text(audioSectionTitle(index: index))
                    }
                }
            }

            if let transcript, transcript.recordingID == recording.id {
                Section("Transcript") {
                    LabeledContent("Language", value: LibraryFormatting.language(transcript.languageCode))
                    LabeledContent("Engine", value: "\(transcript.metadata.engine) \(transcript.metadata.engineVersion)")
                    LabeledContent("Model", value: transcript.metadata.modelID)
                    if let coverage = transcript.metadata.coverage {
                        LabeledContent("Status", value: coverage.isComplete
                            ? LibraryFormatting.localized("Complete")
                            : LibraryFormatting.localized("Partial Transcript"))
                    }
                    LabeledContent("Created") {
                        Text(transcript.metadata.createdAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }

                if let diarization = transcript.diarizationMetadata {
                    Section("Speakers") {
                        LabeledContent("Detected", value: String(transcript.speakers.count))

                        ForEach(Array(transcript.speakers.enumerated()), id: \.element.id) { index, speaker in
                            Button {
                                onRenameSpeaker(speaker.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.crop.circle")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(speakerDisplayName(speaker, index: index))
                                            .foregroundStyle(.primary)
                                        Text(defaultSpeakerName(index: index))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 8)

                                    Image(systemName: "pencil")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canEditSpeakers)
                            .help("Rename this speaker")
                        }

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
        .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
    }

    private func defaultSpeakerName(index: Int) -> String {
        String(
            format: LibraryFormatting.localized("Speaker %@"),
            String(index + 1)
        )
    }

    private func speakerDisplayName(_ speaker: Speaker, index: Int) -> String {
        guard let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return defaultSpeakerName(index: index)
        }
        return name
    }

    private func audioSectionTitle(index: Int) -> String {
        if recording.audioAssets.count == 1 {
            return LibraryFormatting.localized("Audio")
        }
        return String(
            format: LibraryFormatting.localized("Audio Track %@"),
            String(index + 1)
        )
    }

    private func roleText(_ role: AudioAssetRole) -> String {
        switch role {
        case .importedOriginal: LibraryFormatting.localized("Imported Original")
        case .microphoneOriginal: LibraryFormatting.localized("Microphone Original")
        case .systemOriginal: LibraryFormatting.localized("System Original")
        case .conversationMix: LibraryFormatting.localized("Conversation Mix")
        }
    }
}
