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
        libraryContainer
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

    @ViewBuilder
    private var libraryContainer: some View {
        if MacOSUICompatibility.usesNativeToolbar {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .toolbar {
                        sidebarToolbar
                    }
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            HSplitView {
                sidebar
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

                detail
                    .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        LibrarySidebar(
            model: model,
            onNewRecording: onNewRecording,
            onImport: { isFileImporterPresented = true }
        )
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
            .recordingDetailEnhancements(
                recording: recording,
                model: model,
                playback: model.playback
            )
            .id(recording.id)
        } else {
            ContentUnavailableView {
                Label("No Recording Selected", systemImage: "waveform")
            } description: {
                Text("Select a recording from the library or start a new one.")
            }
        }
    }
}
