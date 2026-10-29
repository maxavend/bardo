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
    let onToggleArchived: (Set<Recording.ID>) -> Void
    /// Asks for confirmation before the conversations go to the Trash.
    let onRequestTrash: (Set<Recording.ID>) -> Void

    @State private var renameTarget: Recording?

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
        let recordings = visibleRecordings
        // Like Mail and Finder, ⌘-click, ⇧-click and ⌘A select several conversations.
        return List(selection: $model.selectedIDs) {
            ForEach(recordings) { recording in
                RecordingListRow(
                    recording: recording,
                    isFavorite: favorites.contains(recording.id),
                    participants: participantSummary(for: recording.id),
                    status: status(for: recording),
                    isArchived: isSearching && recording.isArchived,
                    snippet: snippet(for: recording.id)
                )
                .tag(recording.id)
            }
        }
        .listStyle(.inset)
        // Rows the macOS List inserts after its first layout keep a one-line default
        // height, clipping the second line of a recording that was just made or
        // imported. Rebuilding the list when its rows change measures every row again;
        // the selection lives in the model, so it survives.
        .id(recordings.map(\.id))
        // Right-clicking a selected row acts on the whole selection; any other row, on
        // that row alone.
        .contextMenu(forSelectionType: Recording.ID.self) { ids in
            let selected = model.recordings.filter { ids.contains($0.id) }
            if !selected.isEmpty {
                contextMenu(for: selected)
            }
        }
        .onDeleteCommand {
            if !model.selectedIDs.isEmpty { onRequestTrash(model.selectedIDs) }
        }
        .onKeyPress(.space) {
            guard model.selection != nil, model.playback.isLoaded else { return .ignored }
            model.playback.togglePlayback()
            return .handled
        }
    }

    @ViewBuilder
    private func contextMenu(for recordings: [Recording]) -> some View {
        let ids = Set(recordings.map(\.id))
        let single = recordings.count == 1 ? recordings.first : nil
        let addsToFavorites = LibrarySelection.addsToFavorites(ids, favorites: favorites)

        if let single {
            Button {
                Task { await model.playRecording(single.id) }
            } label: {
                Label("Reproducir", systemImage: "play")
            }
            .disabled(single.audioAssets.isEmpty)
        }

        Button {
            favorites.set(ids, favorite: addsToFavorites)
        } label: {
            Label(
                addsToFavorites ? "Agregar a Favoritas" : "Quitar de Favoritas",
                systemImage: addsToFavorites ? "star" : "star.slash"
            )
        }

        Divider()

        if let single {
            Button {
                renameTarget = single
            } label: {
                Label("Renombrar…", systemImage: "pencil")
            }
        }

        Button {
            revealInFinder(recordings)
        } label: {
            Label("Mostrar en Finder", systemImage: "folder")
        }

        Divider()

        Button {
            onToggleArchived(ids)
        } label: {
            if LibrarySelection.archives(recordings) {
                Label("Archivar", systemImage: "archivebox")
            } else {
                Label("Desarchivar", systemImage: "tray.and.arrow.up")
            }
        }

        Button(role: .destructive) {
            onRequestTrash(ids)
        } label: {
            Label("Mover a la Papelera…", systemImage: "trash")
        }
        .disabled(recordings.contains { model.isProcessing($0.id) })
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
            case .archived:
                ContentUnavailableView(
                    "No hay archivadas",
                    systemImage: "archivebox",
                    description: Text("Archiva las conversaciones que ya no usas. Salen de la lista, pero siguen en este Mac.")
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
            if let progress = model.transcriptionProgress, progress.stage == .transcribing, progress.fractionCompleted > 0 {
                return .working("Transcribiendo · \(Int((progress.fractionCompleted * 100).rounded())) %")
            }
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

    private func revealInFinder(_ recordings: [Recording]) {
        Task {
            var locations: [URL] = []
            for recording in recordings {
                guard let location = try? await model.managedLocation(for: recording.id) else {
                    model.reportRecordingActionError(String(localized: "Bardo could not locate the managed recording folder."))
                    return
                }
                locations.append(location)
            }
            NSWorkspace.shared.activateFileViewerSelecting(locations)
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
    /// Marks an archived conversation among search results.
    var isArchived = false
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

                if isArchived {
                    Image(systemName: "archivebox")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Archivada")
                        .help("Archivada")
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
