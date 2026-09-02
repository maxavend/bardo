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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(state.title)
                    .font(.title2.weight(.semibold))
                Text(state.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if state.isMultiline {
                TextEditor(text: $value)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(minHeight: 170)
            } else {
                TextField("Speaker name", text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if let onRestore {
                    Button("Restore Original", role: .destructive) {
                        onRestore()
                    }
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(value)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.isMultiline && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: state.isMultiline ? 340 : 190)
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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Name Participants")
                    .font(.title2.weight(.semibold))
                Text("Listen to a short local audio sample for each detected speaker. Leave a name blank to keep the automatic label.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(transcript.speakers.enumerated()), id: \.element.id) { index, speaker in
                        speakerRow(speaker, index: index)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Names") {
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
        .frame(minWidth: 560, minHeight: 360)
    }

    @ViewBuilder
    private func speakerRow(_ speaker: Speaker, index: Int) -> some View {
        let fallback = "Speaker \(index + 1)"
        let preview = model.speakerPreviews.first { $0.speakerID == speaker.id }

        HStack(spacing: 12) {
            Button {
                guard let preview else { return }
                _ = model.playSpeakerPreview(preview)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(preview == nil)
            .help(preview == nil ? "No representative audio sample" : "Play speaker sample")

            TextField(fallback, text: Binding(
                get: { names[speaker.id, default: ""] },
                set: { names[speaker.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Text(fallback)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
