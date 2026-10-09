import AppKit
import SwiftUI

/// The middle column: the conversations in the selected Library filter, or the
/// search results across the whole Library.
struct RecordingListView: View {
    @ObserveInjection var redraw
    let section: BardoLibrarySection
    let searchQuery: String
    @Binding var sort: BardoLibrarySort
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var favorites: BardoFavoritesStore
    let onNewRecording: () -> Void
    let onImport: () -> Void
    let onMoveToTrash: (Recording) -> Void

    @State private var renameTarget: Recording?
    @State private var deletionTarget: Recording?

    private var isSearching: Bool { !searchQuery.isEmpty }

    var body: some View {
        content
            .navigationTitle(isSearching ? "Resultados" : section.title)
            .navigationSubtitle(subtitle)
            .navigationSplitViewColumnWidth(
                min: BardoLayout.listColumnMinWidth,
                ideal: BardoLayout.listColumnIdealWidth,
                max: BardoLayout.listColumnMaxWidth
            )
            .toolbar {
                ToolbarItem {
                    sortMenu
                }
            }
            .sheet(item: $renameTarget) { recording in
                RecordingRenameSheet(
                    recording: recording,
                    onSave: { title in
                        renameTarget = nil
                        Task { await model.renameRecording(recording.id, to: title) }
                    },
                    onCancel: { renameTarget = nil }
                )
            }
            .confirmationDialog(
                "¿Mover «\(deletionTarget.map(LibraryFormatting.recordingTitle) ?? "")» a la Papelera?",
                isPresented: Binding(
                    get: { deletionTarget != nil },
                    set: { if !$0 { deletionTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deletionTarget
            ) { recording in
                Button("Mover a la Papelera", role: .destructive) {
                    onMoveToTrash(recording)
                }
                Button("Cancelar", role: .cancel) {}
            } message: { _ in
                Text("El audio y la transcripción se moverán a la Papelera de macOS, donde podrás recuperarlos.")
            }
            .enableInjection()
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage, model.recordings.isEmpty {
            ContentUnavailableView {
                Label("No pudimos abrir tu biblioteca", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Intentar de nuevo") {
                    Task { await model.reload() }
                }
            }
        } else if model.isLoading && model.recordings.isEmpty {
            ProgressView("Abriendo tu biblioteca…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleRecordings.isEmpty {
            emptyState
        } else {
            recordingList
        }
    }

    private var recordingList: some View {
        List(selection: $model.selection) {
            ForEach(visibleRecordings) { recording in
                RecordingListRow(
                    recording: recording,
                    isFavorite: favorites.contains(recording.id),
                    participants: participantSummary(for: recording.id),
                    status: status(for: recording),
                    snippet: snippet(for: recording.id)
                )
                .tag(recording.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: Recording.ID.self) { ids in
            if let id = ids.first, let recording = model.recordings.first(where: { $0.id == id }) {
                contextMenu(for: recording)
            }
        }
        .onDeleteCommand {
            deletionTarget = model.selectedRecording
        }
        .onKeyPress(.space) {
            guard model.selection != nil, model.playback.isLoaded else { return .ignored }
            model.playback.togglePlayback()
            return .handled
        }
    }

    @ViewBuilder
    private func contextMenu(for recording: Recording) -> some View {
        Button {
            Task { await model.playRecording(recording.id) }
        } label: {
            Label("Reproducir", systemImage: "play")
        }
        .disabled(recording.audioAssets.isEmpty)

        Button {
            favorites.toggle(recording.id)
        } label: {
            Label(
                favorites.contains(recording.id) ? "Quitar de Favoritas" : "Agregar a Favoritas",
                systemImage: favorites.contains(recording.id) ? "star.slash" : "star"
            )
        }

        Divider()

        Button {
            renameTarget = recording
        } label: {
            Label("Renombrar…", systemImage: "pencil")
        }

        Button {
            revealInFinder(recording)
        } label: {
            Label("Mostrar en Finder", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            deletionTarget = recording
        } label: {
            Label("Mover a la Papelera…", systemImage: "trash")
        }
        .disabled(model.isProcessing(recording.id))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Ordenar por", selection: $sort) {
                ForEach(BardoLibrarySort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Ordenar", systemImage: "line.3.horizontal.decrease")
        }
        .help("Ordenar conversaciones")
        .disabled(isSearching || visibleRecordings.isEmpty)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search(text: searchQuery)
        } else {
            switch section {
            case .all:
                ContentUnavailableView {
                    Label("Tu biblioteca está vacía", systemImage: "waveform")
                } description: {
                    Text("Graba una reunión o importa un audio. Bardo lo transcribe de forma privada en este Mac.")
                } actions: {
                    Button("Nueva grabación…", action: onNewRecording)
                        .buttonStyle(.borderedProminent)
                    Button("Importar audio…", action: onImport)
                }
            case .recorded:
                ContentUnavailableView {
                    Label("No hay grabaciones", systemImage: "mic")
                } description: {
                    Text("Las reuniones y notas de voz que grabes en Bardo aparecerán aquí.")
                } actions: {
                    Button("Nueva grabación…", action: onNewRecording)
                }
            case .imported:
                ContentUnavailableView {
                    Label("No hay audios importados", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Arrastra un archivo de audio a esta ventana o impórtalo desde el menú Archivo.")
                } actions: {
                    Button("Importar audio…", action: onImport)
                }
            case .favorites:
                ContentUnavailableView(
                    "No hay favoritas",
                    systemImage: "star",
                    description: Text("Marca una conversación con una estrella para tenerla siempre a mano.")
                )
            }
        }
    }

    // MARK: - Data

    private var visibleRecordings: [Recording] {
        if isSearching {
            return BardoLibrarySort.newest.sorted(
                model.recordings.filter { matches[$0.id] != nil }
            )
        }
        return sort.sorted(model.recordings.filter { section.contains($0, favorites: favorites) })
    }

    private var matches: [Recording.ID: LibrarySearchMatch] {
        guard isSearching else { return [:] }
        var result: [Recording.ID: LibrarySearchMatch] = [:]
        for document in model.searchDocuments {
            if let match = document.match(query: searchQuery) {
                result[document.id] = match
            }
        }
        return result
    }

    private var subtitle: String {
        let count = visibleRecordings.count
        return count == 1 ? "1 conversación" : "\(count) conversaciones"
    }

    private func snippet(for id: Recording.ID) -> AttributedString? {
        guard isSearching, let match = matches[id], match.kind != .title else { return nil }
        return LibraryFormatting.highlighted(match.context, matching: searchQuery, style: .emphasis)
    }

    private func participantSummary(for id: Recording.ID) -> String? {
        guard let document = model.searchDocuments.first(where: { $0.id == id }),
              !document.participantNames.isEmpty else {
            return nil
        }
        let count = document.participantNames.count
        if document.namedParticipants.count == count, count <= 3 {
            return ListFormatter.localizedString(byJoining: document.namedParticipants)
        }
        return count == 1 ? "1 participante" : "\(count) participantes"
    }

    private func status(for recording: Recording) -> RecordingListRow.Status {
        if model.transcriptionRecordingID == recording.id {
            return .working("Transcribiendo")
        }
        if model.diarizationRecordingID == recording.id {
            return .working("Identificando hablantes")
        }
        switch recording.processingState {
        case .completed: return .none
        case .pending: return .note("Sin transcribir")
        case .processing: return .working("En proceso")
        case .failed: return .attention("Revisar")
        }
    }

    // MARK: - Actions

    private func revealInFinder(_ recording: Recording) {
        Task {
            guard let location = try? await model.managedLocation(for: recording.id) else {
                model.reportRecordingActionError(String(localized: "Bardo could not locate the managed recording folder."))
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([location])
        }
    }
}

struct RecordingListRow: View {
    enum Status: Equatable {
        case none
        case note(String)
        case working(String)
        case attention(String)
    }

    let recording: Recording
    let isFavorite: Bool
    let participants: String?
    let status: Status
    let snippet: AttributedString?

    @Environment(\.backgroundProminence) private var backgroundProminence

    private var isSelected: Bool { backgroundProminence == .increased }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(LibraryFormatting.recordingTitle(recording))
                    .font(.headline)
                    .lineLimit(2)

                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Favorita")
                }

                Spacer(minLength: 8)

                Text(LibraryFormatting.listDate(recording.createdAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            HStack(spacing: 6) {
                Text(detail)
                    .lineLimit(1)

                Spacer(minLength: 8)

                statusView
                    .layoutPriority(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let snippet {
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let duration = LibraryFormatting.duration(recording.duration)
        return "\(duration) · \(participants ?? LibraryFormatting.source(recording.sources))"
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .none:
            EmptyView()
        case .note(let text):
            Text(text)
        case .working(let text):
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(text)
            }
        case .attention(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
        }
    }
}
