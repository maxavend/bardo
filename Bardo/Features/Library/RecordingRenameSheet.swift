import SwiftUI

struct RecordingRenameSheet: View {
    let recording: Recording
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @FocusState private var isTitleFocused: Bool

    init(
        recording: Recording,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.recording = recording
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: recording.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Rename Recording"))
                    .font(.title3.weight(.semibold))

                Text(String(localized: "Choose a name that will be used throughout your Library."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField(String(localized: "Recording title"), text: $title)
                .focused($isTitleFocused)
                .onSubmit(save)

            Divider()

            HStack {
                Spacer()

                Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(String(localized: "Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .task {
            isTitleFocused = true
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        onSave(trimmedTitle)
    }
}