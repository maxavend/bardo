import AppKit
import SwiftUI

struct RecordingDetailView: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @Binding var transcriptSearch: String
    @State private var editor: TranscriptEditorState?
    @State private var pendingReplacementAction: TranscriptReplacementAction?
    @State private var isSpeakerNamingPresented = false
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isInspectorPresented = false
    @State private var selectedTab: DetailTab = .transcript
    @State private var processingBeganAt: Date?

    enum DetailTab: String, CaseIterable, Identifiable, Hashable {
        case transcript
        case minutes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcript: String(localized: "Transcripción")
            case .minutes: String(localized: "Minuta")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            contextBar

            switch selectedTab {
            case .transcript:
                TranscriptContentView(
                    recording: recording,
                    model: model,
                    playback: playback,
                    searchText: $transcriptSearch,
                    editor: $editor,
                    isSpeakerNamingPresented: $isSpeakerNamingPresented,
                    onSelectMinutes: { selectedTab = .minutes }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .minutes:
                MeetingMinutesView(
                    recording: recording,
                    model: model,
                    onSwitchToTranscript: { selectedTab = .transcript }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle(recordingDisplayTitle)
        .navigationSubtitle(toolbarSubtitle)
        .searchable(
            text: $transcriptSearch,
            placement: .toolbar,
            prompt: Text(String(localized: "Search Transcript"))
        )
        .toolbar {
            ToolbarItem(id: "bardo.detail.mode", placement: .principal) {
                Picker(String(localized: "Recording View"), selection: $selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 220)
            }

            ToolbarItem(id: "bardo.detail.info", placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(String(localized: "Inspector"), systemImage: "sidebar.trailing")
                }
                .help(
                    isInspectorPresented
                        ? String(localized: "Hide Recording Inspector")
                        : String(localized: "Show Recording Inspector")
                )
            }

            ToolbarItem(id: "bardo.detail.more", placement: .primaryAction) {
                recordingActionsMenu
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            RecordingInspector(
                recording: recording,
                transcript: model.transcript?.recordingID == recording.id ? model.transcript : nil
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !recording.audioAssets.isEmpty || playback.errorMessage != nil {
                FloatingPlaybackBar(recording: recording, playback: playback)
            }
        }
        .onAppear {
            updateProcessingClock(isProcessing: isDetailProcessing)
        }
        .onChange(of: isDetailProcessing) { _, isProcessing in
            updateProcessingClock(isProcessing: isProcessing)
        }
        .onChange(of: recording.id) { _, _ in
            transcriptSearch = ""
            editor = nil
            pendingReplacementAction = nil
            isSpeakerNamingPresented = false
            selectedTab = .transcript
            processingBeganAt = nil
            updateProcessingClock(isProcessing: isDetailProcessing)
        }
        .onChange(of: model.isGeneratingMeetingMinutes) { _, isGenerating in
            if isGenerating {
                selectedTab = .minutes
            }
        }
        .onChange(of: model.shouldPresentSpeakerNamingSheet) { _, shouldPresent in
            guard shouldPresent else { return }
            isSpeakerNamingPresented = true
            model.consumeSpeakerNamingSheetRequest()
        }
        .sheet(item: $editor) { state in
            TranscriptEditorSheet(
                state: state,
                onSave: { value in
                    editor = nil
                    Task {
                        switch state.kind {
                        case .speaker(let speakerID):
                            await model.renameSpeaker(speakerID, to: value)
                        case .segment(let segmentID):
                            await model.updateTranscriptSegment(segmentID, text: value)
                        }
                    }
                },
                onRestore: state.canRestore ? {
                    editor = nil
                    if case .segment(let segmentID) = state.kind {
                        Task { await model.restoreOriginalTranscriptSegment(segmentID) }
                    }
                } : nil
            )
        }
        .sheet(isPresented: $isSpeakerNamingPresented) {
            if let transcript = model.transcript, transcript.recordingID == recording.id {
                SpeakerNamingSheet(transcript: transcript, model: model)
            }
        }
        .alert(item: $pendingReplacementAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.confirmLabel)) {
                    switch action {
                    case .retranscribe:
                        model.beginTranscription()
                    case .rediarize:
                        model.beginDiarization()
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $isRenamePresented) {
            RecordingRenameSheet(
                recording: recording,
                onSave: { title in
                    isRenamePresented = false
                    Task { await model.renameRecording(recording.id, to: title) }
                },
                onCancel: { isRenamePresented = false }
            )
        }
        .confirmationDialog(
            String(localized: "Move Recording to Trash?"),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Move to Trash"), role: .destructive) {
                Task { await model.deleteRecording(recording.id) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String.localizedStringWithFormat(
                String(localized: "This moves the managed audio, transcript, and minutes for \"%@\" to the macOS Trash, where you can recover it."),
                recordingDisplayTitle
            ))
        }
        .enableInjection()
    }

    private var contextBar: some View {
        HStack(spacing: 10) {
            Label(LibraryFormatting.source(recording.sources), systemImage: "waveform")
                .help(toolbarSubtitle)

            if let transcript = model.transcript, transcript.recordingID == recording.id {
                Divider()
                    .frame(height: 14)

                Label(LibraryFormatting.language(transcript.languageCode), systemImage: "globe")

                if !transcript.speakers.isEmpty {
                    Divider()
                        .frame(height: 14)

                    Label(
                        String.localizedStringWithFormat(String(localized: "%lld participantes"), transcript.speakers.count),
                        systemImage: "person.2"
                    )
                }
            }

            if isDetailProcessing || recording.processingState == .failed {
                Divider()
                    .frame(height: 14)
                processingMetadata
            }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, BardoSpacing.detailHorizontal)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var recordingActionsMenu: some View {
        Menu {
            Button {
                isRenamePresented = true
            } label: {
                Label(String(localized: "Rename…"), systemImage: "pencil")
            }
            .disabled(model.isTranscribing || model.isDiarizing)
            .keyboardShortcut("e", modifiers: [.command])

            Button {
                revealInFinder()
            } label: {
                Label(String(localized: "Reveal in Finder"), systemImage: "folder")
            }

            Button {
                Task { await model.copyManagedLocation(recording.id) }
            } label: {
                Label(String(localized: "Copy Location"), systemImage: "doc.on.doc")
            }

            if let transcript = model.transcript,
               transcript.recordingID == recording.id {
                Divider()

                Button {
                    copyTranscript(transcript)
                } label: {
                    Label(String(localized: "Copy Transcript"), systemImage: "doc.on.doc")
                }
                .disabled(transcript.text.isEmpty)

                Button {
                    if transcript.diarizationMetadata != nil, transcript.hasNamedSpeakers {
                        pendingReplacementAction = .rediarize
                    } else {
                        model.beginDiarization()
                    }
                } label: {
                    Label(
                        transcript.diarizationMetadata == nil
                            ? String(localized: "Identify Speakers")
                            : String(localized: "Identify Speakers Again"),
                        systemImage: "person.2.wave.2"
                    )
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)

                Button {
                    if transcript.hasManualChanges {
                        pendingReplacementAction = .retranscribe
                    } else {
                        model.beginTranscription()
                    }
                } label: {
                    Label(String(localized: "Transcribe Again…"), systemImage: "arrow.clockwise")
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)
            }

            Divider()

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label(String(localized: "Move to Trash"), systemImage: "trash")
            }
            .disabled(model.isTranscribing || model.isDiarizing || model.isGeneratingMeetingMinutes)
            .keyboardShortcut(.delete, modifiers: [.command])
        } label: {
            Label(String(localized: "More"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help(String(localized: "More recording and transcript actions"))
        .accessibilityLabel(String(localized: "More recording and transcript actions"))
    }

    private var recordingDisplayTitle: String {
        LibraryFormatting.recordingTitle(recording)
    }

    private var toolbarSubtitle: String {
        "\(recording.createdAt.formatted(.dateTime.day().month(.wide).year())) · \(LibraryFormatting.duration(recording.duration))"
    }

    private var isDetailProcessing: Bool {
        model.isTranscribing
            || (model.isDiarizing && model.diarizationRecordingID == recording.id)
            || model.isGeneratingMeetingMinutes
            || recording.processingState == .processing
    }

    @ViewBuilder
    private var processingMetadata: some View {
        if isDetailProcessing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(processingBeganAt ?? context.date)
                Label(
                    String.localizedStringWithFormat(
                        String(localized: "Tiempo procesando %@"),
                        LibraryFormatting.duration(elapsed)
                    ),
                    systemImage: "hourglass"
                )
            }
        } else if recording.processingState == .failed {
            Label(String(localized: "Needs attention"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func updateProcessingClock(isProcessing: Bool) {
        if isProcessing {
            processingBeganAt = processingBeganAt ?? Date()
        } else {
            processingBeganAt = nil
        }
    }

    private func copyTranscript(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(transcript.text, forType: .string) {
            model.reportRecordingActionFeedback(String(localized: "Transcript copied"))
        }
    }

    private func revealInFinder() {
        Task {
            guard let location = try? await model.managedLocation(for: recording.id) else {
                model.reportRecordingActionError(String(localized: "Bardo could not locate the managed recording folder."))
                return
            }
            let target = FileManager.default.fileExists(atPath: location.path)
                ? location
                : location.deletingLastPathComponent()
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}