import AppKit
import SwiftUI

struct BardoWorkspaceSectionView: View {
    let section: BardoLibrarySection
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var favorites: BardoFavoritesStore
    let onOpenRecording: (Recording.ID) -> Void
    let onNewRecording: () -> Void
    let onImport: () -> Void

    var body: some View {
        switch section {
        case .home:
            BardoHomeView(
                model: model,
                favorites: favorites,
                onOpenRecording: onOpenRecording,
                onNewRecording: onNewRecording,
                onImport: onImport
            )
        case .recordings, .imported, .minutes, .favorites:
            BardoCollectionView(
                section: section,
                model: model,
                favorites: favorites,
                onOpenRecording: onOpenRecording
            )
        case .trash:
            BardoTrashView()
        }
    }
}

private struct BardoHomeView: View {
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var favorites: BardoFavoritesStore
    let onOpenRecording: (Recording.ID) -> Void
    let onNewRecording: () -> Void
    let onImport: () -> Void

    private var recent: [Recording] {
        Array(model.recordings.sorted { $0.createdAt > $1.createdAt }.prefix(6))
    }

    private var processing: [Recording] {
        model.recordings.filter { recording in
            recording.processingState == .processing
                || model.transcriptionRecordingID == recording.id
                || model.diarizationRecordingID == recording.id
                || (model.isGeneratingMeetingMinutes && model.selection == recording.id)
        }
    }

    private var minuteRecordings: [Recording] {
        Array(
            model.recordings
                .filter { model.recordingIDsWithMinutes.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(4)
        )
    }

    private var favoriteRecordings: [Recording] {
        Array(
            model.recordings
                .filter { favorites.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(4)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Inicio")
                        .font(.largeTitle.weight(.semibold))

                    HStack(spacing: 10) {
                        Button(action: onNewRecording) {
                            Label("Nueva grabación", systemImage: "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut("r", modifiers: [.command])

                        Button(action: onImport) {
                            Label("Importar audio…", systemImage: "square.and.arrow.down")
                        }
                        .controlSize(.large)
                    }

                    Text("Graba una reunión o importa un audio. Bardo lo procesa de forma privada en este Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !processing.isEmpty {
                    homeSection("En proceso") {
                        ForEach(processing) { recording in
                            BardoHomeRecordingRow(
                                recording: recording,
                                detail: processingDescription(for: recording),
                                isProcessing: true
                            ) {
                                onOpenRecording(recording.id)
                            }
                        }
                    }
                }

                if !recent.isEmpty {
                    homeSection("Recientes") {
                        ForEach(recent) { recording in
                            BardoHomeRecordingRow(
                                recording: recording,
                                detail: recording.createdAt.formatted(.relative(presentation: .named)),
                                isProcessing: false
                            ) {
                                onOpenRecording(recording.id)
                            }
                        }
                    }
                }

                if !minuteRecordings.isEmpty {
                    homeSection("Minutas recientes") {
                        ForEach(minuteRecordings) { recording in
                            BardoHomeRecordingRow(
                                recording: recording,
                                detail: "Minuta disponible",
                                isProcessing: false
                            ) {
                                onOpenRecording(recording.id)
                            }
                        }
                    }
                }

                if !favoriteRecordings.isEmpty {
                    homeSection("Favoritos") {
                        ForEach(favoriteRecordings) { recording in
                            BardoHomeRecordingRow(
                                recording: recording,
                                detail: LibraryFormatting.duration(recording.duration),
                                isProcessing: false
                            ) {
                                onOpenRecording(recording.id)
                            }
                        }
                    }
                }

                if model.recordings.isEmpty && !model.isLoading {
                    ContentUnavailableView {
                        Label("Tu biblioteca está vacía", systemImage: "waveform")
                    } description: {
                        Text("Cuando grabes o importes una conversación, aparecerá aquí.")
                    } actions: {
                        Button("Nueva grabación", action: onNewRecording)
                            .buttonStyle(.borderedProminent)
                        Button("Importar audio…", action: onImport)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Inicio")
    }

    @ViewBuilder
    private func homeSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content()
            }
        }
    }

    private func processingDescription(for recording: Recording) -> String {
        if model.transcriptionRecordingID == recording.id {
            return "Transcribiendo la conversación"
        }
        if model.diarizationRecordingID == recording.id {
            return "Identificando a los hablantes"
        }
        if model.isGeneratingMeetingMinutes && model.selection == recording.id {
            return "Preparando la minuta"
        }
        return "Procesando"
    }
}

private struct BardoHomeRecordingRow: View {
    let recording: Recording
    let detail: String
    let isProcessing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: LibraryFormatting.sourceSymbol(recording.sources))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LibraryFormatting.recordingTitle(recording))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(LibraryFormatting.duration(recording.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum BardoLibrarySort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case name

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Más recientes"
        case .oldest: "Más antiguas"
        case .name: "Nombre"
        }
    }
}

private struct BardoCollectionView: View {
    let section: BardoLibrarySection
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var favorites: BardoFavoritesStore
    let onOpenRecording: (Recording.ID) -> Void

    @State private var selection = Set<Recording.ID>()
    @State private var sort: BardoLibrarySort = .newest
    @State private var renameTarget: Recording?
    @State private var deleteTarget: Recording?

    private var filtered: [Recording] {
        let values = model.recordings.filter { recording in
            switch section {
            case .recordings:
                return true
            case .imported:
                return recording.sources.contains(.importedFile)
            case .minutes:
                return model.recordingIDsWithMinutes.contains(recording.id)
            case .favorites:
                return favorites.contains(recording.id)
            case .home, .trash:
                return false
            }
        }

        switch sort {
        case .newest:
            return values.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return values.sorted { $0.createdAt < $1.createdAt }
        case .name:
            return values.sorted {
                LibraryFormatting.recordingTitle($0)
                    .localizedCaseInsensitiveCompare(LibraryFormatting.recordingTitle($1)) == .orderedAscending
            }
        }
    }

    var body: some View {
        Group {
            if model.isLoading && model.recordings.isEmpty {
                ProgressView("Abriendo tu biblioteca…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { recording in
                        row(recording)
                            .tag(recording.id)
                            .onTapGesture(count: 2) {
                                onOpenRecording(recording.id)
                            }
                    }
                }
            }
        }
        .navigationTitle(section.title)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Picker("Ordenar", selection: $sort) {
                        ForEach(BardoLibrarySort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label("Ordenar", systemImage: "arrow.up.arrow.down")
                }
                .help("Ordenar conversaciones")
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
            "¿Mover la conversación a la Papelera?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Mover a la Papelera", role: .destructive) {
                guard let recording = deleteTarget else { return }
                deleteTarget = nil
                favorites.remove(recording.id)
                Task { await model.deleteRecording(recording.id) }
            }
            Button("Cancelar", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("El audio, la transcripción y la minuta se moverán a la Papelera de macOS.")
        }
    }

    private func row(_ recording: Recording) -> some View {
        HStack(spacing: 12) {
            Image(systemName: LibraryFormatting.sourceSymbol(recording.sources))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(LibraryFormatting.recordingTitle(recording))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if favorites.contains(recording.id) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Favorito")
                    }
                }

                Text(rowMetadata(recording))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let participants = participantLabel(for: recording.id) {
                Text(participants)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
            }

            stateView(recording)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onOpenRecording(recording.id)
            } label: {
                Label("Abrir", systemImage: "arrow.forward")
            }

            Button {
                favorites.toggle(recording.id)
            } label: {
                Label(
                    favorites.contains(recording.id) ? "Quitar de Favoritos" : "Agregar a Favoritos",
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
                deleteTarget = recording
            } label: {
                Label("Mover a la Papelera", systemImage: "trash")
            }
            .disabled(model.isTranscribing || model.isDiarizing || model.isGeneratingMeetingMinutes)
        }
    }

    private func rowMetadata(_ recording: Recording) -> String {
        [
            recording.createdAt.formatted(.dateTime.day().month(.abbreviated).year()),
            LibraryFormatting.duration(recording.duration),
            LibraryFormatting.source(recording.sources)
        ].joined(separator: " · ")
    }

    private func participantLabel(for id: Recording.ID) -> String? {
        guard let names = model.searchDocuments.first(where: { $0.id == id })?.participantNames,
              !names.isEmpty else {
            return nil
        }
        if names.count == 1 { return names[0] }
        return "\(names.count) participantes"
    }

    @ViewBuilder
    private func stateView(_ recording: Recording) -> some View {
        if model.transcriptionRecordingID == recording.id {
            Label("Transcribiendo", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.diarizationRecordingID == recording.id {
            Label("Hablantes", systemImage: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if recording.processingState == .failed {
            Label("Revisar", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if recording.processingState == .processing {
            ProgressView()
                .controlSize(.small)
        } else {
            Text(LibraryFormatting.state(recording.processingState))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: section.symbol)
        } description: {
            Text(emptyDetail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch section {
        case .recordings: "No hay grabaciones"
        case .imported: "No hay archivos importados"
        case .minutes: "No hay minutas todavía"
        case .favorites: "No tienes favoritos"
        case .home, .trash: ""
        }
    }

    private var emptyDetail: String {
        switch section {
        case .recordings: "Las reuniones que grabes aparecerán aquí."
        case .imported: "Importa un audio para comenzar."
        case .minutes: "Genera una minuta desde cualquier conversación transcrita."
        case .favorites: "Marca una conversación con una estrella para tenerla siempre a mano."
        case .home, .trash: ""
        }
    }

    private func revealInFinder(_ recording: Recording) {
        Task {
            guard let location = try? await model.managedLocation(for: recording.id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([location])
        }
    }
}

struct BardoSearchResultsView: View {
    let query: String
    @ObservedObject var model: LibraryViewModel
    let onOpenRecording: (Recording.ID) -> Void

    private var matches: [LibrarySearchMatch] {
        model.searchDocuments
            .compactMap { $0.match(query: query) }
            .sorted { lhs, rhs in
                let leftDate = model.recordings.first(where: { $0.id == lhs.recordingID })?.createdAt ?? .distantPast
                let rightDate = model.recordings.first(where: { $0.id == rhs.recordingID })?.createdAt ?? .distantPast
                return leftDate > rightDate
            }
    }

    var body: some View {
        Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(matches) { match in
                    Button {
                        onOpenRecording(match.recordingID)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: match.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(match.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(match.context)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }

                            Spacer(minLength: 12)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Resultados")
    }
}

private struct BardoTrashView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Papelera", systemImage: "trash")
        } description: {
            Text("Bardo usa la Papelera de macOS. Puedes recuperar una conversación desde Finder mientras no hayas vaciado la Papelera.")
        } actions: {
            Button("Abrir Papelera en Finder") {
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
                NSWorkspace.shared.open(url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Papelera")
    }
}
