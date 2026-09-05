import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObserveInjection var redraw
    @ObservedObject var model: LibraryViewModel
    private let captureMenu: AnyView?
    private let activeCaptureBanner: AnyView?

    @State private var isFileImporterPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var recordingSearchText = ""
    @State private var transcriptSearchText = ""

    init(
        model: LibraryViewModel,
        topAccessory: AnyView? = nil,
        captureMenu: AnyView? = nil,
        activeCaptureBanner: AnyView? = nil
    ) {
        self.model = model
        self.captureMenu = captureMenu
        self.activeCaptureBanner = activeCaptureBanner ?? topAccessory
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(model: model, searchText: $recordingSearchText) {
                isFileImporterPresented = true
            }
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let activeCaptureBanner {
                        activeCaptureBanner
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(
            text: $recordingSearchText,
            placement: .sidebar,
            prompt: Text(String(localized: "Search Recordings"))
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if let captureMenu {
                    captureMenu
                }

                Button {
                    isFileImporterPresented = true
                } label: {
                    Label(String(localized: "Import Audio"), systemImage: "square.and.arrow.down")
                }
                .help(String(localized: "Import Audio (⇧⌘O)"))
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.isImporting || model.isTranscribing || model.isDiarizing)
            }
        }
        .task {
            await model.reload()
        }
        .task(id: model.selection) {
            await model.prepareSelection()
        }
        .onChange(of: model.selection) { _, _ in
            transcriptSearchText = ""
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
            String(localized: "Audio Import Failed"),
            isPresented: Binding(
                get: { model.importErrorMessage != nil },
                set: { if !$0 { model.clearImportError() } }
            )
        ) {
            Button(String(localized: "OK")) { model.clearImportError() }
        } message: {
            Text(model.importErrorMessage ?? String(localized: "The audio could not be imported."))
        }
        .alert(
            String(localized: "Recording Action Failed"),
            isPresented: Binding(
                get: { model.recordingActionErrorMessage != nil },
                set: { if !$0 { model.clearRecordingActionError() } }
            )
        ) {
            Button(String(localized: "OK")) { model.clearRecordingActionError() }
        } message: {
            Text(model.recordingActionErrorMessage ?? String(localized: "Bardo could not complete that action."))
        }
        .onDisappear {
            model.cancelTranscription()
            model.cancelDiarization()
            model.cancelMeetingMinutes()
            model.stopPlayback()
        }
        .frame(minWidth: 900, minHeight: 560)
        .enableInjection()
    }

    @ViewBuilder
    private var detail: some View {
        if let recording = model.selectedRecording {
            RecordingDetailView(
                recording: recording,
                model: model,
                playback: model.playback,
                transcriptSearch: $transcriptSearchText
            )
        } else {
            ContentUnavailableView {
                Label(String(localized: "Select a Recording"), systemImage: "waveform")
            } description: {
                Text(String(localized: "Choose a recording from the sidebar to play audio, read its transcript, or inspect details."))
            } actions: {
                Button(String(localized: "Import Audio")) {
                    isFileImporterPresented = true
                }
            }
        }
    }
}