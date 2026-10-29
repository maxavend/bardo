import SwiftUI
import UniformTypeIdentifiers

/// The main window: Library filters, the conversations they contain, and the
/// selected conversation, whose details open as a sheet — the same three-column
/// shape as Mail, Notes and Voice Memos.
struct LibraryView: View {
    @ObserveInjection var redraw
    @ObservedObject var model: LibraryViewModel

    private let captureMenu: AnyView?
    private let activeCaptureBanner: AnyView?
    private let liveRecorder: AnyView?
    private let isFocusMode: Bool
    private let onNewRecording: () -> Void

    @ObservedObject private var favorites = BardoFavoritesStore.shared
    @SceneStorage("bardo.library.section") private var selectedSection: BardoLibrarySection = .all
    @State private var isInfoPresented = false
    /// The selected conversation in the full player, which takes the whole window.
    @State private var isFullPlayerPresented = false
    @AppStorage("bardo.library.sort") private var sort: BardoLibrarySort = .newest
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isFileImporterPresented = false
    @State private var isIssuesReviewPresented = false
    @State private var searchText = ""
    /// Conversations waiting for confirmation before they go to the Trash.
    @State private var trashCandidates: Set<Recording.ID> = []
    @FocusState private var isSearchFocused: Bool
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    init(
        model: LibraryViewModel,
        topAccessory: AnyView? = nil,
        captureMenu: AnyView? = nil,
        activeCaptureBanner: AnyView? = nil,
        liveRecorder: AnyView? = nil,
        isFocusMode: Bool = false,
        onNewRecording: @escaping () -> Void = {
            NotificationCenter.default.post(name: BardoCommandNotification.newRecording, object: nil)
        }
    ) {
        self.model = model
        self.captureMenu = captureMenu
        self.activeCaptureBanner = activeCaptureBanner ?? topAccessory
        self.liveRecorder = liveRecorder
        self.isFocusMode = isFocusMode
        self.onNewRecording = onNewRecording
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if isFullPlayerPresented, let recording = model.selectedRecording {
                FullPlayerView(
                    recording: recording,
                    model: model,
                    playback: model.playback,
                    searchQuery: searchQuery,
                    onClose: { isFullPlayerPresented = false }
                )
            } else {
                libraryColumns
            }
        }
        // One toolbar search field for the window; it searches the whole Library, or
        // the conversation open in the full player.
        // Keep the prompt short so it never truncates in a narrow toolbar.
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Buscar"))
        .searchFocused($isSearchFocused)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: model.selection) { _, selection in
            if selection == nil { isFullPlayerPresented = false }
        }
        // Details open as a sheet: nothing slides in beside the transcript, so the
        // columns and the search field never move.
        .sheet(isPresented: $isInfoPresented) {
            if let recording = model.selectedRecording {
                RecordingInfoSheet(
                    recording: recording,
                    transcript: model.transcript?.recordingID == recording.id ? model.transcript : nil,
                    model: model
                )
            }
        }
        .focusedSceneValue(\.libraryInspector, model.selectedRecording == nil ? nil : $isInfoPresented)
        .focusedSceneValue(\.librarySelection, selectionCommands)
        .confirmationDialog(
            trashConfirmationTitle,
            isPresented: Binding(
                get: { !trashCandidates.isEmpty },
                set: { if !$0 { trashCandidates = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Mover a la Papelera", role: .destructive) {
                moveToTrash(trashCandidates)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(trashCandidates.count == 1
                ? "El audio y la transcripción se moverán a la Papelera de macOS, donde podrás recuperarlos."
                : "Sus audios y transcripciones se moverán a la Papelera de macOS, donde podrás recuperarlos.")
        }
        .task {
            await model.reload()
            selectFirstRecordingIfNeeded()
        }
        // Focus mode leaves the recorder alone in the window, as the native split view
        // does when its columns are collapsed.
        .onChange(of: isFocusMode) { _, focused in
            withAnimation { columnVisibility = focused ? .detailOnly : .all }
        }
        .task(id: model.selection) {
            await model.prepareSelection()
        }
        .onChange(of: selectedSection) { _, _ in
            selectFirstRecordingIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.importAudio)) { _ in
            isFileImporterPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.focusSearch)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.libraryChanged)) { _ in
            Task {
                await model.reload()
                selectFirstRecordingIfNeeded()
            }
        }
        .sheet(isPresented: $isIssuesReviewPresented) {
            LibraryIssuesSheet(model: model)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.importAudio(from: urls) }
            case .failure(let error):
                model.reportImportFailure(error)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isImporting, !urls.isEmpty else { return false }
            Task { await model.importAudio(from: urls) }
            return true
        }
        .alert(
            "No pudimos importar el audio",
            isPresented: Binding(
                get: { model.importErrorMessage != nil },
                set: { if !$0 { model.clearImportError() } }
            )
        ) {
            Button("Aceptar") { model.clearImportError() }
        } message: {
            Text(model.importErrorMessage ?? "Revisa el archivo e inténtalo de nuevo.")
        }
        .alert(
            "No pudimos completar la acción",
            isPresented: Binding(
                get: { model.recordingActionErrorMessage != nil },
                set: { if !$0 { model.clearRecordingActionError() } }
            )
        ) {
            Button("Aceptar") { model.clearRecordingActionError() }
        } message: {
            Text(model.recordingActionErrorMessage ?? "Inténtalo de nuevo.")
        }
        .frame(minWidth: BardoLayout.windowMinWidth, minHeight: BardoLayout.windowMinHeight)
        #if DEBUG
        .onDesignReviewCommand(perform: performDesignReview)
        #endif
        .enableInjection()
    }

    #if DEBUG
    /// Kept out of `body`, whose long chain of modifiers is already slow to type-check.
    private func performDesignReview(_ step: DesignReview.Step) {
        switch step.action {
        case "section":
            if let section = BardoLibrarySection(rawValue: step.value) { selectedSection = section }
        case "open":
            let list = sort.sorted(model.recordings)
            if let index = Int(step.value), list.indices.contains(index) { model.selection = list[index].id }
        case "deselect":
            model.selection = nil
        case "select":
            // Several conversations, as with ⌘-click: `select:0,1,2`.
            let list: [Recording] = sectionRecordings
            let indices: [Int] = step.value.split(separator: ",").compactMap { Int($0) }
            let ids: [Recording.ID] = indices.filter { list.indices.contains($0) }.map { list[$0].id }
            model.selectedIDs = Set(ids)
        case "archive":
            toggleArchived(model.selectedIDs)
        case "trashSelection":
            trashCandidates = model.selectedIDs
        case "search":
            searchText = step.value
        case "inspector":
            isInfoPresented = true
        case "player":
            isFullPlayerPresented = true
        case "sidebar":
            columnVisibility = step.value == "hidden" ? .doubleColumn : .all
        case "settings":
            openSettings()
        case "issues":
            isIssuesReviewPresented = true
        case "mute":
            model.playback.setVolume(Float(step.value) ?? 0)
        case "transcribe":
            model.beginTranscription()
        case "identify":
            model.beginDiarization()
        case "import":
            Task { await model.importAudio(from: [URL(fileURLWithPath: step.value)]) }
        case "trash":
            if let recording = model.selectedRecording { moveToTrash([recording.id]) }
        default:
            break
        }
    }
    #endif

    /// The Library's three columns: filters, conversations and the selected one.
    private var libraryColumns: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(
                model: model,
                favorites: favorites,
                selection: $selectedSection,
                onReviewIssues: { isIssuesReviewPresented = true }
            )
        } content: {
            RecordingListView(
                section: selectedSection,
                searchQuery: searchQuery,
                sort: $sort,
                model: model,
                favorites: favorites,
                onNewRecording: onNewRecording,
                onImport: { isFileImporterPresented = true },
                onToggleArchived: toggleArchived,
                onRequestTrash: { trashCandidates = $0 }
            )
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    newRecordingButton

                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Importar audio", systemImage: "square.and.arrow.down")
                    }
                    .help("Importar audio (⇧⌘O)")
                    .disabled(model.isImporting)
                }
            }
        } detail: {
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: BardoLayout.detailColumnMinWidth, ideal: 640)
                .safeAreaInset(edge: .top, spacing: 0) {
                    // The recorder has its own controls; the banner returns while
                    // another conversation is open during the recording.
                    if let activeCaptureBanner, !showsLiveRecorder {
                        activeCaptureBanner
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                    }
                }
        }
    }

    @ViewBuilder
    private var newRecordingButton: some View {
        if let captureMenu {
            captureMenu
        } else {
            Button(action: onNewRecording) {
                Label("Nueva grabación", systemImage: "record.circle")
            }
            .help("Nueva grabación (⌘N)")
        }
    }

    /// Like Voice Memos, the recording in progress takes the detail column until another
    /// conversation is chosen.
    private var showsLiveRecorder: Bool {
        liveRecorder != nil && model.selectedIDs.isEmpty
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let liveRecorder, showsLiveRecorder {
            liveRecorder
        } else if let recording = model.selectedRecording {
            RecordingDetailView(
                recording: recording,
                model: model,
                playback: model.playback,
                searchQuery: searchQuery,
                isInfoPresented: $isInfoPresented,
                isFullPlayerPresented: $isFullPlayerPresented,
                onToggleArchived: { toggleArchived([$0.id]) },
                onMoveToTrash: { moveToTrash([$0.id]) }
            )
        } else if model.selectedIDs.count > 1 {
            MultipleSelectionView(
                count: model.selectedIDs.count,
                archives: LibrarySelection.archives(selectedRecordings),
                onToggleArchived: { toggleArchived(model.selectedIDs) },
                onMoveToTrash: { trashCandidates = model.selectedIDs }
            )
        } else if model.recordings.isEmpty {
            // The list's empty state already invites the first recording; one call to
            // action is enough.
            Color.clear
        } else {
            ContentUnavailableView(
                "Ninguna conversación seleccionada",
                systemImage: "text.bubble",
                description: Text("Elige una conversación de la lista para leer su transcripción.")
            )
        }
    }

    /// The conversations of the selected filter, in list order.
    private var sectionRecordings: [Recording] {
        sort.sorted(model.recordings.filter { selectedSection.contains($0, favorites: favorites) })
    }

    /// The selected conversations, in Library order.
    private var selectedRecordings: [Recording] {
        model.recordings.filter { model.selectedIDs.contains($0.id) }
    }

    /// Like Mail and Notes, keep something readable in the detail column: when the
    /// selection is not part of the current filter, select its first conversation.
    private func selectFirstRecordingIfNeeded() {
        // While recording, an empty selection shows the recorder.
        guard searchQuery.isEmpty, liveRecorder == nil else { return }
        let visible = Set(sectionRecordings.map(\.id))
        let kept = model.selectedIDs.intersection(visible)
        if !kept.isEmpty {
            if kept != model.selectedIDs { model.selectedIDs = kept }
            return
        }
        model.selection = sectionRecordings.first?.id
    }

    /// When conversations leave the list on screen, the next one takes the selection,
    /// as in Mail. Search results keep them, archived or not.
    private func selectNeighbor(ofLeaving ids: Set<Recording.ID>, list: [Recording.ID]) {
        guard !model.selectedIDs.isDisjoint(with: ids) else { return }
        model.selection = LibrarySelection.neighbor(of: ids, in: list)
    }

    /// One path for the list, the menus and ⌃⌘A: archives the conversations, or moves
    /// them back to the Library when all of them are archived.
    private func toggleArchived(_ ids: Set<Recording.ID>) {
        let recordings = model.recordings.filter { ids.contains($0.id) }
        guard !recordings.isEmpty else { return }
        let archive = LibrarySelection.archives(recordings)
        if searchQuery.isEmpty {
            let list = sectionRecordings.map(\.id)
            let leaving = Set(recordings.map(\.id)).filter { id in
                list.contains(id) && (archive ? selectedSection != .archived : selectedSection == .archived)
            }
            selectNeighbor(ofLeaving: leaving, list: list)
        }
        Task { await model.setArchived(ids, archive) }
    }

    /// One path for the list, the "More" menu and ⌘⌫: the next conversation takes the
    /// selection, as in Mail, and the favourite goes with the conversation.
    private func moveToTrash(_ ids: Set<Recording.ID>) {
        let list = searchQuery.isEmpty ? sectionRecordings.map(\.id) : searchResultIDs
        selectNeighbor(ofLeaving: ids, list: list)
        Task {
            if ids.count == 1, let id = ids.first {
                await model.deleteRecording(id)
            } else {
                await model.deleteRecordings(ids)
            }
            let remaining = Set(model.recordings.map(\.id))
            favorites.set(ids.subtracting(remaining), favorite: false)
        }
    }

    /// Search results, newest first, as the list shows them.
    private var searchResultIDs: [Recording.ID] {
        let matching = Set(model.searchDocuments.filter { $0.match(query: searchQuery) != nil }.map(\.id))
        return BardoLibrarySort.newest.sorted(model.recordings.filter { matching.contains($0.id) }).map(\.id)
    }

    private var trashConfirmationTitle: String {
        if trashCandidates.count == 1,
           let recording = model.recordings.first(where: { trashCandidates.contains($0.id) }) {
            return "¿Mover «\(LibraryFormatting.recordingTitle(recording))» a la Papelera?"
        }
        return "¿Mover \(trashCandidates.count) conversaciones a la Papelera?"
    }

    /// What the menu bar can do with the selected conversations.
    private var selectionCommands: LibrarySelectionCommands? {
        let recordings = selectedRecordings
        guard !recordings.isEmpty else { return nil }
        let ids = Set(recordings.map(\.id))
        let addsToFavorites = LibrarySelection.addsToFavorites(ids, favorites: favorites)
        return LibrarySelectionCommands(
            archives: LibrarySelection.archives(recordings),
            addsToFavorites: addsToFavorites,
            toggleArchived: { toggleArchived(ids) },
            toggleFavorite: { favorites.set(ids, favorite: addsToFavorites) }
        )
    }
}

/// The detail column while several conversations are selected, as in Mail and Finder.
private struct MultipleSelectionView: View {
    let count: Int
    let archives: Bool
    let onToggleArchived: () -> Void
    let onMoveToTrash: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("\(count) conversaciones seleccionadas", systemImage: "rectangle.stack")
        } actions: {
            Button(archives ? "Archivar" : "Desarchivar", action: onToggleArchived)
            Button("Mover a la Papelera…", role: .destructive, action: onMoveToTrash)
        }
    }
}

/// What the focused window's menu bar items do with its selected conversations.
struct LibrarySelectionCommands {
    /// Archivar, or Desarchivar when every selected conversation is archived.
    var archives: Bool
    var addsToFavorites: Bool
    var toggleArchived: () -> Void
    var toggleFavorite: () -> Void
}

extension FocusedValues {
    /// Whether the focused Library window shows a conversation's details; `nil` when
    /// there is nothing to show.
    @Entry var libraryInspector: Binding<Bool>?
    /// The selected conversations' actions; `nil` when nothing is selected.
    @Entry var librarySelection: LibrarySelectionCommands?
}
