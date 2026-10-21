import SwiftUI

enum TranscriptReplacementAction: String, Identifiable {
    case retranscribe
    case rediarize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .retranscribe:
            "¿Reemplazar los cambios de la transcripción?"
        case .rediarize:
            "¿Volver a identificar a los hablantes?"
        }
    }

    var message: String {
        switch self {
        case .retranscribe:
            "La nueva transcripción reemplazará las correcciones de texto y los nombres de hablantes que hayas hecho manualmente."
        case .rediarize:
            "Bardo volverá a distinguir las voces desde cero. Se conservarán tus correcciones de texto, pero tendrás que revisar los nombres de los hablantes."
        }
    }

    var confirmLabel: String {
        switch self {
        case .retranscribe:
            "Transcribir de nuevo"
        case .rediarize:
            "Identificar de nuevo"
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
            title: "Nombre del hablante",
            initialValue: speaker.name ?? "",
            prompt: "Ponle un nombre a \(fallbackName). Si lo dejas vacío, seguirá usando su nombre automático.",
            canRestore: false,
            isMultiline: false
        )
    }

    static func segment(_ segment: TranscriptSegment) -> TranscriptEditorState {
        TranscriptEditorState(
            kind: .segment(segment.id),
            title: "Editar transcripción",
            initialValue: segment.displayText,
            prompt: "Corrige el texto sin cambiar el momento del audio al que pertenece.",
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

/// Who took part: a sample of each voice to recognise it, a name for each, and one
/// person told apart as two put back together, by hand or when two get the same name.
/// Nothing is saved until Guardar; Cancelar leaves the transcript as it was.
struct SpeakerNamingSheet: View {
    let transcript: Transcript
    @ObservedObject var model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewPlayback = AudioPlaybackController()
    @State private var names: [Speaker.ID: String]
    @State private var merges: [(source: Speaker.ID, target: Speaker.ID)] = []
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

    /// The transcript as it will be saved, with the merges made so far.
    private var draft: Transcript {
        merges.reduce(transcript) { $0.mergingSpeaker($1.source, into: $1.target) }
    }

    var body: some View {
        let draft = draft
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Participantes")
                    .font(.title2.weight(.semibold))
                Text(previewStatus ?? "Escucha cada voz y ponle nombre.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)

            Form {
                Section {
                    ForEach(draft.speakers) { speaker in
                        speakerRow(speaker, in: draft)
                    }
                } footer: {
                    footer(for: draft)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .animation(.default, value: draft.speakers.map(\.id))

            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .bardoSecondaryAction()
                    .keyboardShortcut(.cancelAction)
                Button {
                    isSaving = true
                    Task {
                        await model.saveSpeakerReview(names: names, merges: merges)
                        dismiss()
                    }
                } label: {
                    Text("Guardar")
                        .opacity(isSaving ? 0 : 1)
                        .overlay { if isSaving { ProgressView().controlSize(.small) } }
                }
                .bardoPrimaryAction()
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .disabled(isSaving)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 520)
        .frame(minHeight: 320, idealHeight: CGFloat(170 + 60 * min(draft.speakers.count, 7)), maxHeight: 620)
        .task {
            if model.playback.isPlaying {
                model.playback.pause()
            }
            isPreparingPreviewAudio = true
            _ = await model.prepareSpeakerPreviewPlayback(previewPlayback)
            isPreparingPreviewAudio = false
        }
        .onDisappear {
            previewPlayback.unload()
        }
    }

    /// Said in place of the subtitle while samples are not ready.
    private var previewStatus: String? {
        if isPreparingPreviewAudio { return "Preparando las muestras de voz…" }
        if previewPlayback.errorMessage != nil, !previewPlayback.isLoaded {
            return "Las muestras no están disponibles, pero puedes poner nombres."
        }
        return nil
    }

    // MARK: Rows

    private func speakerRow(_ speaker: Speaker, in draft: Transcript) -> some View {
        // Names and colours from the transcript as it was, so they do not shift as
        // participants are merged.
        let fallback = transcript.defaultName(for: speaker)
        let preview = model.speakerPreviews.first { $0.speakerID == speaker.id }
        let absorbed = merges.filter { $0.target == speaker.id }.count
        return HStack(spacing: 12) {
            sampleButton(for: speaker, preview: preview)

            VStack(alignment: .leading, spacing: 2) {
                Text(fallback)
                    .lineLimit(1)
                Text(caption(preview: preview, absorbed: absorbed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)

            TextField("Nombre", text: nameBinding(speaker.id), prompt: Text("Nombre"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            mergeMenu(for: speaker, in: draft)
        }
        .padding(.vertical, 2)
        .contextMenu { mergeItems(for: speaker, in: draft) }
    }

    private func caption(preview: SpeakerPreview?, absorbed: Int) -> String {
        var parts: [String] = []
        if let preview {
            parts.append("Muestra de \(LibraryFormatting.duration(preview.endTime - preview.startTime))")
        }
        if absorbed > 0 {
            parts.append(absorbed == 1 ? "Incluye 1 fusionado" : "Incluye \(absorbed) fusionados")
        }
        return parts.isEmpty ? "Sin muestra" : parts.joined(separator: " · ")
    }

    /// The speaker's colour from the transcript doubles as the sample control.
    private func sampleButton(for speaker: Speaker, preview: SpeakerPreview?) -> some View {
        let isPlaying = activePreviewSpeakerID == speaker.id && previewPlayback.isPlaying
        let isAvailable = preview != nil && !isPreparingPreviewAudio && previewPlayback.isLoaded
        return Button {
            guard let preview else { return }
            if isPlaying {
                previewPlayback.pause()
            } else {
                activePreviewSpeakerID = speaker.id
                // With separate tracks, a sample plays only the track that voice is on.
                previewPlayback.setFocus(
                    speaker.role == .localUser ? .microphone : (transcript.isPerTrack ? .system : .everyone)
                )
                _ = previewPlayback.playPreview(from: preview.startTime, to: preview.endTime)
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(SpeakerPalette.color(for: speaker.id, in: transcript).gradient, in: .circle)
                .opacity(isAvailable ? 1 : 0.4)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel(isPlaying ? "Pausar muestra" : "Escuchar muestra")
        .help(preview == nil ? "Sin una muestra clara de esta voz" : "Escuchar una muestra de esta voz")
    }

    private func nameBinding(_ id: Speaker.ID) -> Binding<String> {
        Binding(get: { names[id, default: ""] }, set: { names[id] = $0 })
    }

    // MARK: Merging

    private func mergeMenu(for speaker: Speaker, in draft: Transcript) -> some View {
        // Said in words: no symbol says "these two are one person".
        // A list flattens buttons, so the capsule is drawn here, with the menu's arrow.
        Menu {
            mergeItems(for: speaker, in: draft)
        } label: {
            HStack(spacing: 4) {
                Text("Fusionar")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(draft.speakers.count < 2)
        .help("Fusionar con otro participante, si son la misma persona")
    }

    @ViewBuilder
    private func mergeItems(for speaker: Speaker, in draft: Transcript) -> some View {
        Section("Es la misma persona que") {
            ForEach(draft.speakers.filter { $0.id != speaker.id }) { other in
                Button(label(for: other)) { merge(speaker.id, into: other.id) }
            }
        }
    }

    private func label(for speaker: Speaker) -> String {
        names[speaker.id]?.nonEmptyTrimmed ?? transcript.defaultName(for: speaker)
    }

    private func merge(_ sourceID: Speaker.ID, into targetID: Speaker.ID) {
        // The name that will show is kept, whichever side it was typed on.
        if names[targetID]?.nonEmptyTrimmed == nil, let name = names[sourceID]?.nonEmptyTrimmed {
            names[targetID] = name
        }
        withAnimation { merges.append((sourceID, targetID)) }
    }

    /// Offers to merge participants given the same name, and to undo the last merge.
    @ViewBuilder
    private func footer(for draft: Transcript) -> some View {
        let duplicates = draft.speakersSharingAName(names)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(duplicates, id: \.self) { group in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(.secondary)
                    Text("\(names[group[0]]?.nonEmptyTrimmed ?? "") aparece \(group.count) veces.")
                    Button("Fusionar") {
                        for source in group.dropFirst() { merge(source, into: group[0]) }
                    }
                    .buttonStyle(.link)
                }
            }
            if !merges.isEmpty {
                HStack(spacing: 8) {
                    Text(merges.count == 1 ? "Fusionaste 1 participante." : "Fusionaste \(merges.count) participantes.")
                    Button("Deshacer") { withAnimation { _ = merges.popLast() } }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
