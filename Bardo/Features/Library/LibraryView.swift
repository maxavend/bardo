import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
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
                            .padding(.top, 8)
                            .padding(.bottom, 6)
                            .padding(.horizontal, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: activeCaptureBanner != nil)
            .toolbar {
                if let captureMenu {
                    ToolbarItem(placement: .primaryAction) {
                        captureMenu
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
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
            model.stopPlayback()
        }
        .frame(minWidth: 900, minHeight: 560)
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
            .id(recording.id)
        } else {
            ContentUnavailableView {
                Label(String(localized: "Select a Recording"), systemImage: "waveform")
            } description: {
                Text(String(localized: "Choose a recording from the sidebar to play audio, read its transcript, or inspect details."))
            }
        }
    }
}
