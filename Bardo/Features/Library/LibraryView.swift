import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    let onNewRecording: () -> Void

    @State private var isFileImporterPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(
        model: LibraryViewModel,
        onNewRecording: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onNewRecording = onNewRecording
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(
                model: model,
                onNewRecording: onNewRecording,
                onImport: { isFileImporterPresented = true }
            )
            .toolbar {
                sidebarToolbar
            }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await model.reload()
        }
        .task(id: model.selection) {
            await model.prepareSelection()
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
            guard !model.isImporting,
                  !urls.isEmpty else {
                return false
            }
            Task { await model.importAudio(from: urls) }
            return true
        }
        .alert(
            "Audio Import Failed",
            isPresented: Binding(
                get: { model.importErrorMessage != nil },
                set: { if !$0 { model.clearImportError() } }
            )
        ) {
            Button("OK") { model.clearImportError() }
        } message: {
            Text(model.importErrorMessage ?? "The audio could not be imported.")
        }
        .onDisappear {
            // Transcription and diarization are recording-scoped jobs, not view-scoped jobs.
            // Navigating or rebuilding the split view must never cancel important processing.
            model.stopPlayback()
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(id: "bardo.library.import", placement: .automatic) {
            Button {
                isFileImporterPresented = true
            } label: {
                Label("Import Audio", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model.isImporting)
            .help("Import audio")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let recording = model.selectedRecording {
            RecordingDetailView(
                recording: recording,
                model: model,
                playback: model.playback
            )
            .id(recording.id)
        } else {
            ContentUnavailableView {
                Label("Select a Recording", systemImage: "waveform")
            } description: {
                Text("Choose a recording from the sidebar to play audio, read its transcript, or inspect details.")
            }
        }
    }
}
