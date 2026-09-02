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
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Recording")
                .font(.title2.weight(.semibold))

            TextField("Recording title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task {
            isTitleFocused = true
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
