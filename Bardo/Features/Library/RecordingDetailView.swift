import AppKit
import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @Binding var transcriptSearch: String
    @State private var editor: TranscriptEditorState?
    @State private var pendingReplacementAction: TranscriptReplacementAction?
    @State private var isInspectorPresented = false
    @State private var isSpeakerNamingPresented = false
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var selectedTab: DetailTab = .transcript
    @Namespace private var tabAnimationNamespace

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript
        case minutes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcript: String(localized: "Transcript")
            case .minutes: String(localized: "Meeting Minutes")
            }
        }

        var systemImage: String {
            switch self {
            case .transcript: "captions.bubble"
            case .minutes: "list.bullet.clipboard"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            recordingHeader
                .padding(.horizontal, BardoSpacing.detailHorizontal)
                .padding(.top, BardoSpacing.detailTop)
                .padding(.bottom, 8)

            tabSwitcher
                .padding(.horizontal, BardoSpacing.detailHorizontal)
                .padding(.bottom, 10)

            Divider()
                .opacity(0.6)

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
        .navigationTitle("")
        .searchable(text: $transcriptSearch, placement: .toolbar, prompt: Text(String(localized: "Search Transcript")))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !recording.audioAssets.isEmpty || playback.errorMessage != nil {
                FloatingPlaybackBar(recording: recording, playback: playback)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
                                transcript.diarizationMetadata == nil ? String(localized: "Identify Speakers") : String(localized: "Identify Speakers Again"),
                                systemImage: "person.2.wave.2"
                            )
                        }
                        .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)

                        Menu {
                            ForEach(TranscriptionOption.catalog) { option in
                                Button {
                                    model.selectedTranscriptionPreset = option.preset
                                    if transcript.hasManualChanges {
                                        pendingReplacementAction = .retranscribe
                                    } else {
                                        model.beginTranscription()
                                    }
                                } label: {
                                    HStack {
                                        Text(option.label)
                                        if model.selectedTranscriptionPreset == option.preset {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
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
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.fill.quaternary.opacity(0.8), in: Circle())
                        .contentShape(Circle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help(String(localized: "More recording and transcript actions"))
                .accessibilityLabel(String(localized: "More recording and transcript actions"))

                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(isInspectorPresented ? String(localized: "Hide Inspector") : String(localized: "Show Inspector"), systemImage: "sidebar.right")
                }
                .help(isInspectorPresented ? String(localized: "Hide Inspector") : String(localized: "Show Inspector"))
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            RecordingInspector(recording: recording, transcript: model.transcript)
        }
        .onChange(of: recording.id) { _, _ in
            transcriptSearch = ""
            editor = nil
            pendingReplacementAction = nil
            isSpeakerNamingPresented = false
            selectedTab = .transcript
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
    }

    private var recordingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recordingDisplayTitle)
                .font(.title2.weight(.bold))
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                metadataLabel(
                    recording.createdAt.formatted(.dateTime.month(.wide).day().year().hour().minute()),
                    systemImage: "calendar"
                )
                metadataLabel(LibraryFormatting.duration(recording.duration), systemImage: "clock")
                    .monospacedDigit()
                metadataLabel(LibraryFormatting.source(recording.sources), systemImage: "waveform")

                if let transcript = model.transcript, transcript.recordingID == recording.id {
                    metadataLabel(LibraryFormatting.language(transcript.languageCode), systemImage: "globe")
                }

                if recording.processingState == .processing {
                    ProgressView()
                        .controlSize(.small)
                } else if recording.processingState == .failed {
                    Label(String(localized: "Needs attention"), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: 800, alignment: .leading)
    }

    private var recordingDisplayTitle: String {
        LibraryFormatting.recordingTitle(recording)
    }

    private func metadataLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: .medium))

                        Text(tab.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))

                        if tab == .minutes, let minutes = model.meetingMinutes, minutes.recordingID == recording.id {
                            Circle()
                                .fill(.tint)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "activeTabIndicator", in: tabAnimationNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(tab == .transcript ? "1" : "2", modifiers: [.command])
            }
        }
        .padding(3)
        .background(.fill.quaternary.opacity(0.7), in: Capsule())
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
