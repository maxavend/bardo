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
    @State private var names: [Speaker.ID: String]

    init(transcript: Transcript, model: LibraryViewModel) {
        self.transcript = transcript
        self.model = model
        _names = State(initialValue: Dictionary(
            uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0.name ?? "") }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Name Participants"))
                    .font(.title3.weight(.semibold))

                Text(String(localized: "Listen to a short local audio sample for each detected speaker. Leave a name blank to keep the automatic label."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Section(String(localized: "Participants")) {
                    ForEach(Array(transcript.speakers.enumerated()), id: \.element.id) { index, speaker in
                        speakerRow(speaker, index: index)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()

                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Save Names")) {
                    Task {
                        await model.renameSpeakers(names)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 390)
    }

    private func speakerRow(_ speaker: Speaker, index: Int) -> some View {
        let fallback = String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
        let preview = model.speakerPreviews.first { $0.speakerID == speaker.id }

        return LabeledContent(fallback) {
            HStack(spacing: 10) {
                Button {
                    guard let preview else { return }
                    _ = model.playSpeakerPreview(preview)
                } label: {
                    Label(String(localized: "Play Speaker Sample"), systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }
                .disabled(preview == nil)
                .help(
                    preview == nil
                        ? String(localized: "No representative audio sample")
                        : String(localized: "Play speaker sample")
                )

                TextField(
                    fallback,
                    text: Binding(
                        get: { names[speaker.id, default: ""] },
                        set: { names[speaker.id] = $0 }
                    )
                )
                .frame(minWidth: 220)
            }
        }
    }
}