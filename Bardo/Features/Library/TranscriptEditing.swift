import SwiftUI

enum TranscriptReplacementAction: String, Identifiable {
    case retranscribe
    case rediarize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .retranscribe:
            LibraryFormatting.localized("Replace Manual Transcript Changes?")
        case .rediarize:
            LibraryFormatting.localized("Replace Speaker Names?")
        }
    }

    var message: String {
        switch self {
        case .retranscribe:
            LibraryFormatting.localized("Transcribing again creates a new transcript and removes manual text corrections and speaker names from the current transcript.")
        case .rediarize:
            LibraryFormatting.localized("Identifying speakers again creates new speaker clusters. Existing speaker names will be removed because the new clusters may represent different people. Manual text corrections are preserved.")
        }
    }

    var confirmLabel: String {
        switch self {
        case .retranscribe:
            LibraryFormatting.localized("Transcribe Again")
        case .rediarize:
            LibraryFormatting.localized("Identify Speakers Again")
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
            title: LibraryFormatting.localized("Name Speaker"),
            initialValue: speaker.name ?? "",
            prompt: String(
                format: LibraryFormatting.localized("Give %@ a name. Leave it blank to restore the automatic label."),
                fallbackName
            ),
            canRestore: false,
            isMultiline: false
        )
    }

    static func segment(_ segment: TranscriptSegment) -> TranscriptEditorState {
        TranscriptEditorState(
            kind: .segment(segment.id),
            title: LibraryFormatting.localized("Edit Transcript"),
            initialValue: segment.displayText,
            prompt: LibraryFormatting.localized("Correct the readable transcript while Bardo preserves the original timing evidence."),
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
