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
        .onDesignReviewCommand { step in
            switch step.action {
            case "section":
                if let section = BardoLibrarySection(rawValue: step.value) { selectedSection = section }
            case "open":
                let list = sort.sorted(model.recordings)
                if let index = Int(step.value), list.indices.contains(index) { model.selection = list[index].id }
            case "deselect":
                model.selection = nil
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
                if let recording = model.selectedRecording { moveToTrash(recording) }
            default:
                break
            }
        }
        #endif
        .enableInjection()
    }

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
                onMoveToTrash: moveToTrash
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
        liveRecorder != nil && model.selection == nil
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
                onMoveToTrash: moveToTrash
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

    /// Like Mail and Notes, keep something readable in the detail column: when the
    /// selection is not part of the current filter, select its first conversation.
    private func selectFirstRecordingIfNeeded() {
        // While recording, an empty selection shows the recorder.
        guard searchQuery.isEmpty, liveRecorder == nil else { return }
        let visible = sectionRecordings
        if let selection = model.selection, visible.contains(where: { $0.id == selection }) {
            return
        }
        model.selection = visible.first?.id
    }

    /// One path for the list, the "More" menu and ⌘⌫: the next conversation takes the
    /// selection, as in Mail, and the favourite goes with the conversation.
    private func moveToTrash(_ recording: Recording) {
        if model.selection == recording.id {
            let list = sectionRecordings
            if let index = list.firstIndex(where: { $0.id == recording.id }) {
                let neighbor = index + 1 < list.count ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
                model.selection = neighbor?.id
            }
        }
        Task {
            await model.deleteRecording(recording.id)
            if !model.recordings.contains(where: { $0.id == recording.id }) {
                favorites.remove(recording.id)
            }
        }
    }
}

extension FocusedValues {
    /// Whether the focused Library window shows a conversation's details; `nil` when
    /// there is nothing to show.
    @Entry var libraryInspector: Binding<Bool>?
}
