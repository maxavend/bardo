import SwiftUI
import UniformTypeIdentifiers

/// The main window: Library filters, the conversations they contain, and the
/// selected conversation with an optional inspector — the same three-column
/// shape as Mail, Notes and Voice Memos.
struct LibraryView: View {
    @ObserveInjection var redraw
    @ObservedObject var model: LibraryViewModel

    private let captureMenu: AnyView?
    private let activeCaptureBanner: AnyView?
    private let onNewRecording: () -> Void

    @ObservedObject private var favorites = BardoFavoritesStore.shared
    @SceneStorage("bardo.library.section") private var selectedSection: BardoLibrarySection = .all
    @SceneStorage("bardo.library.inspector") private var isInspectorPresented = false
    @AppStorage("bardo.library.sort") private var sort: BardoLibrarySort = .newest
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isFileImporterPresented = false
    @State private var searchText = ""
    @State private var windowWidth: CGFloat = 0
    @State private var sidebarHiddenForInspector = false
    @FocusState private var isSearchFocused: Bool
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    init(
        model: LibraryViewModel,
        topAccessory: AnyView? = nil,
        captureMenu: AnyView? = nil,
        activeCaptureBanner: AnyView? = nil,
        onNewRecording: @escaping () -> Void = {
            NotificationCenter.default.post(name: BardoCommandNotification.newRecording, object: nil)
        }
    ) {
        self.model = model
        self.captureMenu = captureMenu
        self.activeCaptureBanner = activeCaptureBanner ?? topAccessory
        self.onNewRecording = onNewRecording
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(model: model, favorites: favorites, selection: $selectedSection)
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
                    if let activeCaptureBanner {
                        activeCaptureBanner
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                    }
                }
                .inspector(isPresented: $isInspectorPresented) {
                    inspectorContent
                        .inspectorColumnWidth(
                            min: BardoLayout.inspectorMinWidth,
                            ideal: BardoLayout.inspectorIdealWidth,
                            max: BardoLayout.inspectorMaxWidth
                        )
                }
        }
        // One toolbar search field for the window; it searches the whole Library.
        // Keep the prompt short so it never truncates in a narrow toolbar.
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Buscar"))
        .searchFocused($isSearchFocused)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            windowWidth = width
            fitColumnsToWindow()
        }
        .onChange(of: isInspectorPresented) { _, _ in
            fitColumnsToWindow()
        }
        .focusedSceneValue(\.libraryInspector, model.selectedRecording == nil ? nil : $isInspectorPresented)
        .task {
            await model.reload()
            selectFirstRecordingIfNeeded()
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
                isInspectorPresented = true
            case "sidebar":
                columnVisibility = step.value == "hidden" ? .doubleColumn : .all
            case "settings":
                openSettings()
            case "mute":
                model.playback.setVolume(0)
            case "transcribe":
                model.beginTranscription()
            case "trash":
                if let recording = model.selectedRecording { moveToTrash(recording) }
            default:
                break
            }
        }
        #endif
        .enableInjection()
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

    @ViewBuilder
    private var detailColumn: some View {
        if let recording = model.selectedRecording {
            RecordingDetailView(
                recording: recording,
                model: model,
                playback: model.playback,
                searchQuery: searchQuery,
                isInspectorPresented: $isInspectorPresented,
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

    @ViewBuilder
    private var inspectorContent: some View {
        if let recording = model.selectedRecording {
            RecordingInspector(
                recording: recording,
                transcript: model.transcript?.recordingID == recording.id ? model.transcript : nil
            )
        } else {
            ContentUnavailableView(
                "Sin información",
                systemImage: "info.circle",
                description: Text("Elige una conversación para ver sus detalles.")
            )
        }
    }

    /// The transcript needs a readable measure. When the inspector would squeeze it,
    /// hide the sidebar for as long as the inspector needs the room, as Mail does.
    private func fitColumnsToWindow() {
        guard windowWidth > 0 else { return }
        let needed = BardoLayout.librarySidebarIdealWidth + BardoLayout.listColumnMinWidth
            + BardoLayout.detailColumnMinWidth + BardoLayout.inspectorMinWidth
        if isInspectorPresented, windowWidth < needed, columnVisibility == .all {
            sidebarHiddenForInspector = true
            columnVisibility = .doubleColumn
        } else if sidebarHiddenForInspector, !isInspectorPresented || windowWidth >= needed {
            sidebarHiddenForInspector = false
            columnVisibility = .all
        }
    }

    /// The conversations of the selected filter, in list order.
    private var sectionRecordings: [Recording] {
        sort.sorted(model.recordings.filter { selectedSection.contains($0, favorites: favorites) })
    }

    /// Like Mail and Notes, keep something readable in the detail column: when the
    /// selection is not part of the current filter, select its first conversation.
    private func selectFirstRecordingIfNeeded() {
        guard searchQuery.isEmpty else { return }
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
    /// Whether the focused Library window shows its inspector; `nil` when there is
    /// nothing to inspect.
    @Entry var libraryInspector: Binding<Bool>?
}
