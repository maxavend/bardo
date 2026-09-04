import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObserveInjection var redraw
    @ObservedObject var model: LibraryViewModel

    private let captureMenu: AnyView?
    private let activeCaptureBanner: AnyView?
    private let onNewRecording: () -> Void

    @ObservedObject private var favorites = BardoFavoritesStore.shared
    @State private var selectedSection: BardoLibrarySection = .home
    @State private var navigationPath = NavigationPath()
    @State private var isFileImporterPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var globalSearchText = ""
    @State private var transcriptSearchText = ""
    @State private var isInspectorPresented = false
    @FocusState private var isSearchFocused: Bool

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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(model: model, selection: $selectedSection)
        } detail: {
            NavigationStack(path: $navigationPath) {
                workspaceRoot
                    .navigationDestination(for: UUID.self) { recordingID in
                        recordingDestination(recordingID)
                    }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let activeCaptureBanner {
                    activeCaptureBanner
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(
            text: $globalSearchText,
            placement: .toolbar,
            prompt: Text("Buscar conversaciones, texto, minutas o participantes")
        )
        .searchFocused($isSearchFocused)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if let captureMenu {
                    captureMenu
                } else {
                    Button(action: onNewRecording) {
                        Label("Nueva grabación", systemImage: "record.circle")
                    }
                    .help("Nueva grabación (⌘N)")
                }

                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Importar audio", systemImage: "square.and.arrow.down")
                }
                .help("Importar audio (⇧⌘O)")
                .disabled(model.isImporting)
            }

            ToolbarItem(placement: .primaryAction) {
                if !navigationPath.isEmpty {
                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Label("Información", systemImage: "sidebar.trailing")
                    }
                    .help(isInspectorPresented ? "Ocultar información" : "Mostrar información")
                }
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            if let recording = model.selectedRecording, !navigationPath.isEmpty {
                RecordingInspector(
                    recording: recording,
                    transcript: model.transcript?.recordingID == recording.id ? model.transcript : nil,
                    meetingMinutes: model.meetingMinutes?.recordingID == recording.id ? model.meetingMinutes : nil
                )
                .frame(minWidth: 280, idealWidth: 320)
            } else {
                ContentUnavailableView(
                    "Sin información",
                    systemImage: "info.circle",
                    description: Text("Abre una conversación para ver sus detalles.")
                )
                .frame(minWidth: 280)
            }
        }
        .task {
            if let saved = UserDefaults.standard.string(forKey: "bardo.start-section"),
               let section = BardoLibrarySection(rawValue: saved) {
                selectedSection = section
            }
            await model.reload()
        }
        .task(id: model.selection) {
            await model.prepareSelection()
        }
        .onChange(of: selectedSection) { _, _ in
            navigationPath = NavigationPath()
            transcriptSearchText = ""
            if globalSearchText.isEmpty {
                model.selection = nil
            }
        }
        .onChange(of: globalSearchText) { _, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                navigationPath = NavigationPath()
                isInspectorPresented = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.importAudio)) { _ in
            isFileImporterPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.focusSearch)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.toggleInspector)) { _ in
            guard !navigationPath.isEmpty else { return }
            isInspectorPresented.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: BardoCommandNotification.libraryChanged)) { _ in
            navigationPath = NavigationPath()
            model.selection = nil
            Task { await model.reload() }
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
        .frame(minWidth: 980, minHeight: 620)
        .enableInjection()
    }

    @ViewBuilder
    private var workspaceRoot: some View {
        let query = globalSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            BardoSearchResultsView(
                query: query,
                model: model,
                onOpenRecording: openRecording
            )
        } else {
            BardoWorkspaceSectionView(
                section: selectedSection,
                model: model,
                favorites: favorites,
                onOpenRecording: openRecording,
                onNewRecording: onNewRecording,
                onImport: { isFileImporterPresented = true }
            )
        }
    }

    @ViewBuilder
    private func recordingDestination(_ recordingID: Recording.ID) -> some View {
        if let recording = model.recordings.first(where: { $0.id == recordingID }) {
            RecordingDetailView(
                recording: recording,
                model: model,
                playback: model.playback,
                transcriptSearch: $transcriptSearchText
            )
            .onAppear {
                if model.selection != recordingID {
                    model.selection = recordingID
                }
            }
        } else {
            ContentUnavailableView(
                "Esta conversación ya no está disponible",
                systemImage: "waveform.badge.exclamationmark",
                description: Text("Puede haberse movido o eliminado.")
            )
        }
    }

    private func openRecording(_ recordingID: Recording.ID) {
        globalSearchText = ""
        transcriptSearchText = ""
        model.selection = recordingID

        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }
        navigationPath.append(recordingID)
    }
}
