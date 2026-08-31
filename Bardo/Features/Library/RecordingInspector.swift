import SwiftUI

struct RecordingInspector: View {
    let recording: Recording
    let transcript: Transcript?
    let canEditSpeakers: Bool
    let onRenameSpeaker: (Speaker.ID, String) -> Void

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Created") {
                    Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute())
                }
                LabeledContent("Duration", value: LibraryFormatting.duration(recording.duration))
                LabeledContent("Source", value: LibraryFormatting.source(recording.sources))
            }

            if let transcript, transcript.recordingID == recording.id,
               transcript.diarizationMetadata != nil {
                Section("Speakers") {
                    LabeledContent("Detected", value: String(transcript.speakers.count))

                    ForEach(Array(transcript.speakers.enumerated()), id: \.element.id) { index, speaker in
                        SpeakerNameRow(
                            speaker: speaker,
                            index: index,
                            canEdit: canEditSpeakers,
                            onCommit: { name in
                                onRenameSpeaker(speaker.id, name)
                            }
                        )
                    }
                }
            }

            if let transcript, transcript.recordingID == recording.id {
                Section("Transcript") {
                    LabeledContent("Language", value: LibraryFormatting.language(transcript.languageCode))
                    if let coverage = transcript.metadata.coverage {
                        LabeledContent(
                            "Status",
                            value: coverage.isComplete
                                ? LibraryFormatting.localized("Complete")
                                : LibraryFormatting.localized("Partial Transcript")
                        )
                    }
                    LabeledContent("Created") {
                        Text(transcript.metadata.createdAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }
            }

            Section {
                DisclosureGroup("Technical Details") {
                    if let transcript, transcript.recordingID == recording.id {
                        LabeledContent("Transcript Engine", value: "\(transcript.metadata.engine) \(transcript.metadata.engineVersion)")
                        LabeledContent("Transcript Model", value: transcript.metadata.modelID)

                        if let diarization = transcript.diarizationMetadata {
                            LabeledContent("Speaker Engine", value: "\(diarization.engine) \(diarization.engineVersion)")
                            LabeledContent("Speaker Model", value: diarization.modelID)
                        }
                    }

                    ForEach(Array(recording.audioAssets.enumerated()), id: \.element.id) { index, asset in
                        if index > 0 {
                            Divider()
                        }
                        Text(audioSectionTitle(index: index))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LabeledContent("File", value: asset.originalFileName)
                        LabeledContent("Codec", value: asset.metadata.codec)
                        LabeledContent("Sample Rate", value: LibraryFormatting.sampleRate(asset.metadata.sampleRate))
                        LabeledContent("Channels", value: String(asset.metadata.channelCount))
                        if recording.audioAssets.count > 1 {
                            LabeledContent("Role", value: roleText(asset.role))
                        }
                    }

                    LabeledContent("Recording ID") {
                        Text(recording.id.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 270, ideal: 310, max: 380)
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

private struct SpeakerNameRow: View {
    let speaker: Speaker
    let index: Int
    let canEdit: Bool
    let onCommit: (String) -> Void

    @State private var draftName: String
    @FocusState private var isFocused: Bool

    init(
        speaker: Speaker,
        index: Int,
        canEdit: Bool,
        onCommit: @escaping (String) -> Void
    ) {
        self.speaker = speaker
        self.index = index
        self.canEdit = canEdit
        self.onCommit = onCommit
        _draftName = State(initialValue: speaker.name ?? "")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                TextField(defaultSpeakerName, text: $draftName, prompt: Text(defaultSpeakerName))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($isFocused)
                    .disabled(!canEdit)
                    .onSubmit(commitIfNeeded)

                Text(hasName ? defaultSpeakerName : LibraryFormatting.localized("Add name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: isFocused) { wasFocused, nowFocused in
            if wasFocused && !nowFocused {
                commitIfNeeded()
            }
        }
        .onChange(of: speaker.name) { _, newName in
            if !isFocused {
                draftName = newName ?? ""
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var defaultSpeakerName: String {
        String(
            format: LibraryFormatting.localized("Speaker %@"),
            String(index + 1)
        )
    }

    private var hasName: Bool {
        !(speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func commitIfNeeded() {
        let normalized = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalized != existing else { return }
        onCommit(normalized)
    }
}
