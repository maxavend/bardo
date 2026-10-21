import SwiftUI

/// A moment's title and note, written like a quick note rather than filled in like a
/// form. What is typed is kept when the popover closes, however it closes, as in
/// Calendar; the trash removes the moment instead.
struct MomentEditor: View {
    let moment: RecordingMoment
    let onCommit: (_ title: String, _ note: String?) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var isRemoved = false
    @FocusState private var isTitleFocused: Bool

    init(moment: RecordingMoment, onCommit: @escaping (String, String?) -> Void, onRemove: @escaping () -> Void) {
        self.moment = moment
        self.onCommit = onCommit
        self.onRemove = onRemove
        // A moment still named after its time shows that name as the placeholder.
        let isDefault = moment.title == RecordingMoment.defaultTitle(at: moment.time)
        _title = State(initialValue: isDefault ? "" : moment.title)
        _note = State(initialValue: moment.note ?? "")
    }

    var body: some View {
        NoteEditorLayout(
            caption: "Momento · \(LibraryFormatting.duration(moment.time))",
            mark: AnyView(Circle().fill(ConversationWaveformStyle.momentTint).frame(width: 7, height: 7)),
            removeLabel: "Quitar momento",
            remove: {
                isRemoved = true
                onRemove()
                dismiss()
            },
            done: { dismiss() }
        ) {
            TextField("Título", text: $title, prompt: Text(RecordingMoment.defaultTitle(at: moment.time)))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .focused($isTitleFocused)
                .onSubmit { dismiss() }
            TextField("Nota", text: $note, prompt: Text("Agregar una nota"), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
        }
        .onAppear { isTitleFocused = true }
        .onDisappear {
            if !isRemoved { onCommit(title, note) }
        }
    }
}

/// A section's name, edited the same way as a moment.
struct SectionEditor: View {
    let section: RecordingSection
    let onCommit: (_ title: String) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isRemoved = false
    @FocusState private var isTitleFocused: Bool

    init(section: RecordingSection, onCommit: @escaping (String) -> Void, onRemove: @escaping () -> Void) {
        self.section = section
        self.onCommit = onCommit
        self.onRemove = onRemove
        _title = State(initialValue: section.title)
    }

    var body: some View {
        NoteEditorLayout(
            caption: "Sección desde \(LibraryFormatting.duration(section.start))",
            mark: AnyView(Capsule().fill(.secondary).frame(width: 2, height: 11)),
            removeLabel: "Quitar sección",
            remove: {
                isRemoved = true
                onRemove()
                dismiss()
            },
            done: { dismiss() }
        ) {
            TextField("Nombre", text: $title, prompt: Text(section.title))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .focused($isTitleFocused)
                .onSubmit { dismiss() }
        }
        .onAppear { isTitleFocused = true }
        .onDisappear {
            if !isRemoved, !title.isEmpty { onCommit(title) }
        }
    }
}

/// The shared shape of both editors: what and when, the fields, then remove and done.
private struct NoteEditorLayout<Fields: View>: View {
    let caption: String
    let mark: AnyView
    let removeLabel: String
    let remove: () -> Void
    let done: () -> Void
    @ViewBuilder let fields: Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                mark
                Text(caption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            fields
            Divider()
                .padding(.top, 2)
            HStack {
                Button(role: .destructive, action: remove) {
                    Label(removeLabel, systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(removeLabel)
                Spacer()
                Button("Listo", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
