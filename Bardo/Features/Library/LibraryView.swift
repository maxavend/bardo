import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    private let topAccessory: AnyView

    @State private var isFileImporterPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(model: LibraryViewModel, topAccessory: AnyView? = nil) {
        self.model = model
        self.topAccessory = topAccessory ?? AnyView(EmptyView())
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(model: model) {
                isFileImporterPresented = true
            }
            .toolbar {
                sidebarToolbar
            }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .top, spacing: 0) {
            topAccessory
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label(String(localized: "Settings"), systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.regular)
                .help(String(localized: "Open Bardo Settings"))
            }
        }
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
                  !model.isTranscribing,
                  !model.isDiarizing,
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
        .alert(
            "Recording Action Failed",
            isPresented: Binding(
                get: { model.recordingActionErrorMessage != nil },
                set: { if !$0 { model.clearRecordingActionError() } }
            )
        ) {
            Button("OK") { model.clearRecordingActionError() }
        } message: {
            Text(model.recordingActionErrorMessage ?? "Bardo could not complete that action.")
        }
        .onDisappear {
            model.cancelTranscription()
            model.cancelDiarization()
            model.stopPlayback()
        }
        .frame(minWidth: 980, minHeight: 620)
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                isFileImporterPresented = true
            } label: {
                Label("Import Audio", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .controlSize(.regular)
            .disabled(model.isImporting || model.isTranscribing || model.isDiarizing)
            .help("Import audio")
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button {
                Task { await model.reload() }
            } label: {
                Label("Reload Library", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .controlSize(.regular)
            .disabled(model.isLoading || model.isImporting || model.isTranscribing || model.isDiarizing)
            .help("Reload library")
            .keyboardShortcut("r", modifiers: [.command])
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
