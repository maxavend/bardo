import SwiftUI

enum TranscriptReplacementAction: String, Identifiable {
    case retranscribe
    case rediarize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .retranscribe:
            "Replace Manual Transcript Changes?"
        case .rediarize:
            "Replace Speaker Names?"
        }
    }

    var message: String {
        switch self {
        case .retranscribe:
            "Transcribing again creates a new transcript and removes manual text corrections and speaker names from the current transcript."
        case .rediarize:
            "Identifying speakers again creates new speaker clusters. Existing speaker names will be removed because the new clusters may represent different people. Manual text corrections are preserved."
        }
    }

    var confirmLabel: String {
        switch self {
        case .retranscribe:
            "Transcribe Again"
        case .rediarize:
            "Identify Speakers Again"
        }
    }
}

struct TranscriptEditorState: Identifiable {
    enum Kind {
        case speaker(Speaker.ID)
        case segment(TranscriptSegment.ID)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let initialValue: String
    let prompt: String
    let canRestore: Bool
    let isMultiline: Bool

    static func speaker(_ speaker: Speaker, fallbackName: String) -> TranscriptEditorState {
        TranscriptEditorState(
            kind: .speaker(speaker.id),
            title: "Name Speaker",
            initialValue: speaker.name ?? "",
            prompt: "Give \(fallbackName) a name. Leave it blank to restore the automatic label.",
            canRestore: false,
            isMultiline: false
        )
    }

    static func segment(_ segment: TranscriptSegment) -> TranscriptEditorState {
        TranscriptEditorState(
            kind: .segment(segment.id),
            title: "Edit Transcript",
            initialValue: segment.displayText,
            prompt: "Correct the readable transcript while Bardo preserves the original timing evidence.",
            canRestore: segment.editedText != nil,
            isMultiline: true
        )
    }
}

struct TranscriptEditorSheet: View {
    let state: TranscriptEditorState
    let onSave: (String) -> Void
    let onRestore: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @FocusState private var isEditorFocused: Bool

    init(
        state: TranscriptEditorState,
        onSave: @escaping (String) -> Void,
        onRestore: (() -> Void)?
    ) {
        self.state = state
        self.onSave = onSave
        self.onRestore = onRestore
        _value = State(initialValue: state.initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.title3.weight(.semibold))

                Text(state.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            editorControl

            Divider()

            HStack(spacing: 10) {
                if let onRestore {
                    Button {
                        onRestore()
                    } label: {
                        Label(String(localized: "Restore Original"), systemImage: "arrow.uturn.backward")
                    }
                }

                Spacer()

                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Save")) {
                    onSave(value)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.isMultiline && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: state.isMultiline ? 340 : 190)
        .task {
            isEditorFocused = true
        }
    }

    @ViewBuilder
    private var editorControl: some View {
        if state.isMultiline {
            TextEditor(text: $value)
                .font(.body)
                .focused($isEditorFocused)
                .frame(minHeight: 180)
        } else {
            TextField(String(localized: "Speaker name"), text: $value)
                .focused($isEditorFocused)
        }
    }
}

struct SpeakerNamingSheet: View {
    let transcript: Transcript
    @ObservedObject var model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewPlayback = AudioPlaybackController()
    @State private var names: [Speaker.ID: String]
    @State private var activePreviewSpeakerID: Speaker.ID?
    @State private var isPreparingPreviewAudio = true
    @State private var isSaving = false

    init(transcript: Transcript, model: LibraryViewModel) {
        self.transcript = transcript
        self.model = model
        _names = State(initialValue: Dictionary(
            uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0.name ?? "") }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if let errorMessage = previewPlayback.errorMessage,
               !previewPlayback.isLoaded,
               !isPreparingPreviewAudio {
                Label {
                    Text(String(localized: "Audio previews are unavailable. You can still name participants."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "speaker.slash")
                        .foregroundStyle(.secondary)
                }
                .help(errorMessage)
            }

            participantList

            Divider()

            HStack(spacing: 10) {
                Spacer()

                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button {
                    isSaving = true
                    Task {
                        await model.renameSpeakers(names)
                        dismiss()
                    }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "Save Names"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 340)
        .task {
            isPreparingPreviewAudio = true
            _ = await model.prepareSpeakerPreviewPlayback(previewPlayback)
            isPreparingPreviewAudio = false
        }
        .onDisappear {
            previewPlayback.unload()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Name Participants"))
                    .font(.title3.weight(.semibold))

                Text(String(localized: "Listen to a short sample from each detected voice, then add names where useful. Empty fields keep Bardo's automatic speaker labels."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var participantList: some View {
        GroupBox {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(transcript.speakers.enumerated()), id: \.element.id) { index, speaker in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 42)
                        }

                        speakerRow(speaker, index: index)
                    }
                }
            }
            .frame(maxHeight: 340)
        } label: {
            Text(String(localized: "Participants"))
                .font(.headline)
        }
    }

    private func speakerRow(_ speaker: Speaker, index: Int) -> some View {
        let fallback = String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
        let preview = model.speakerPreviews.first { $0.speakerID == speaker.id }
        let isThisPreviewPlaying = activePreviewSpeakerID == speaker.id && previewPlayback.isPlaying

        return HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(fallback)
                    .font(.callout.weight(.medium))

                if let preview {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Sample · %@"),
                            LibraryFormatting.duration(preview.endTime - preview.startTime)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                } else {
                    Text(String(localized: "No representative sample"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 110, alignment: .leading)

            Spacer(minLength: 12)

            Button {
                guard let preview else { return }

                if isThisPreviewPlaying {
                    previewPlayback.pause()
                } else {
                    activePreviewSpeakerID = speaker.id
                    _ = previewPlayback.playPreview(
                        from: preview.startTime,
                        to: preview.endTime
                    )
                }
            } label: {
                Label(
                    isThisPreviewPlaying
                        ? String(localized: "Pause Sample")
                        : String(localized: "Play Sample"),
                    systemImage: isThisPreviewPlaying ? "pause.fill" : "play.fill"
                )
            }
            .controlSize(.small)
            .disabled(preview == nil || isPreparingPreviewAudio || !previewPlayback.isLoaded)
            .help(
                preview == nil
                    ? String(localized: "No representative audio sample")
                    : String(localized: "Play a short local sample of this speaker")
            )

            TextField(
                String(localized: "Name (optional)"),
                text: Binding(
                    get: { names[speaker.id, default: ""] },
                    set: { names[speaker.id] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 2)
    }
}
