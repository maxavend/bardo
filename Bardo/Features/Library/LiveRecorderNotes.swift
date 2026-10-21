import SwiftUI

/// What the recorder can do besides pausing and finishing: mark moments and sections,
/// rename or discard the recording, and hide the Library around it.
struct LiveRecorderActions {
    /// Where the recording is now on its own timeline.
    var position: () -> TimeInterval
    var addMoment: (TimeInterval) -> RecordingMoment?
    var editMoment: (RecordingMoment.ID, String, String?) -> Void
    var removeMoment: (RecordingMoment.ID) -> Void
    var addSection: (TimeInterval) -> RecordingSection?
    var renameSection: (RecordingSection.ID, String) -> Void
    var removeSection: (RecordingSection.ID) -> Void
    var rename: (String) -> Void
    var discard: () -> Void
    var isFocused: Bool
    var toggleFocus: () -> Void
}

enum LiveRecorderCommand {
    static let newMoment = Notification.Name("Bardo.Command.NewMoment")
    static let newSection = Notification.Name("Bardo.Command.NewSection")
}

/// The recorder's toolbar: Momento, Sección, Silenciar and Más, where a conversation
/// keeps its own actions.
struct LiveRecorderToolbar: ToolbarContent {
    let title: String
    let actions: LiveRecorderActions?
    let isMicrophoneMuted: Bool
    let muteAction: (() -> Void)?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let actions {
                LiveMomentButton(actions: actions)
                LiveSectionButton(actions: actions)
            }
            if let muteAction {
                Button(action: muteAction) {
                    Label(
                        isMicrophoneMuted ? "Activar micrófono" : "Silenciar micrófono",
                        systemImage: isMicrophoneMuted ? "mic.slash.fill" : "mic"
                    )
                }
                .foregroundStyle(isMicrophoneMuted ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .help(isMicrophoneMuted ? "Activar micrófono (⌥⌘S)" : "Silenciar tu micrófono sin pausar el audio del Mac (⌥⌘S)")
            }
            if let actions {
                LiveRecorderMoreMenu(title: title, actions: actions)
            }
        }
    }
}

/// Marks the moment as soon as it is pressed, then lets the person name it and add a
/// note. Whatever is typed is kept when the popover closes, however it closes.
private struct LiveMomentButton: View {
    let actions: LiveRecorderActions

    @State private var moment: RecordingMoment?
    @State private var title = ""
    @State private var note = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        Button(action: mark) {
            Label("Marcar momento", systemImage: "flag")
        }
        .help("Marcar este momento y anotar algo (⌥⌘N)")
        .popover(item: $moment, arrowEdge: .bottom) { moment in
            VStack(alignment: .leading, spacing: 12) {
                Label("Momento · \(LibraryFormatting.duration(moment.time))", systemImage: "flag.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                TextField("Título", text: $title, prompt: Text(RecordingMoment.defaultTitle(at: moment.time)))
                    .textFieldStyle(.roundedBorder)
                    .focused($isTitleFocused)
                    .onSubmit { self.moment = nil }
                TextField("Nota", text: $note, prompt: Text("Nota (opcional)"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                HStack {
                    Button("Quitar", role: .destructive) {
                        actions.removeMoment(moment.id)
                        title = ""
                        note = ""
                        self.moment = nil
                    }
                    Spacer()
                    Button("Guardar") { self.moment = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 300)
            .onAppear { isTitleFocused = true }
            .onDisappear { commit(moment) }
        }
        .onReceive(NotificationCenter.default.publisher(for: LiveRecorderCommand.newMoment)) { _ in
            if moment == nil { mark() }
        }
    }

    private func mark() {
        title = ""
        note = ""
        moment = actions.addMoment(actions.position())
    }

    private func commit(_ moment: RecordingMoment) {
        guard !title.isEmpty || !note.isEmpty else { return }
        actions.editMoment(moment.id, title, note)
        title = ""
        note = ""
    }
}

/// Starts a section where the recording is now and lets the person name it.
private struct LiveSectionButton: View {
    let actions: LiveRecorderActions

    @State private var section: RecordingSection?
    @State private var title = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        Button(action: start) {
            Label("Nueva sección", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .help("Empezar una sección con nombre desde aquí (⇧⌥⌘N)")
        .popover(item: $section, arrowEdge: .bottom) { section in
            VStack(alignment: .leading, spacing: 12) {
                Label("Sección desde \(LibraryFormatting.duration(section.start))", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.headline)
                TextField("Nombre", text: $title, prompt: Text(section.title))
                    .textFieldStyle(.roundedBorder)
                    .focused($isTitleFocused)
                    .onSubmit { self.section = nil }
                HStack {
                    Button("Quitar", role: .destructive) {
                        actions.removeSection(section.id)
                        title = ""
                        self.section = nil
                    }
                    Spacer()
                    Button("Guardar") { self.section = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 280)
            .onAppear { isTitleFocused = true }
            .onDisappear {
                if !title.isEmpty { actions.renameSection(section.id, title) }
                title = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LiveRecorderCommand.newSection)) { _ in
            if section == nil { start() }
        }
    }

    private func start() {
        title = ""
        section = actions.addSection(actions.position())
    }
}

/// Less frequent actions, last in the toolbar as everywhere on macOS.
private struct LiveRecorderMoreMenu: View {
    let title: String
    let actions: LiveRecorderActions

    @State private var isRenaming = false
    @State private var newTitle = ""
    @State private var isConfirmingDiscard = false

    var body: some View {
        Menu {
            Button {
                actions.toggleFocus()
            } label: {
                Label(actions.isFocused ? "Salir del modo enfoque" : "Modo enfoque", systemImage: "rectangle.center.inset.filled")
            }
            Button {
                newTitle = title
                isRenaming = true
            } label: {
                Label("Renombrar…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                isConfirmingDiscard = true
            } label: {
                Label("Descartar grabación…", systemImage: "trash")
            }
        } label: {
            Label("Más acciones", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Más acciones")
        .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Renombrar la grabación")
                    .font(.headline)
                TextField("Nombre", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(rename)
                HStack {
                    Spacer()
                    Button("Cancelar", role: .cancel) { isRenaming = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Renombrar", action: rename)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
        .confirmationDialog("¿Descartar esta grabación?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Descartar grabación", role: .destructive, action: actions.discard)
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("La grabación se detiene sin guardarse y su audio va a la Papelera de macOS, donde puedes recuperarlo.")
        }
    }

    private func rename() {
        actions.rename(newTitle)
        isRenaming = false
    }
}
