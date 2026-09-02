import AppKit
import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @State private var transcriptSearch = ""
    @State private var editor: TranscriptEditorState?
    @State private var pendingReplacementAction: TranscriptReplacementAction?
    @State private var isInspectorPresented = false
    @State private var isSpeakerNamingPresented = false
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                recordingHeader

                TranscriptContentView(
                    recording: recording,
                    model: model,
                    playback: playback,
                    searchText: $transcriptSearch,
                    editor: $editor,
                    isSpeakerNamingPresented: $isSpeakerNamingPresented
                )

                if let transcript = model.transcript, transcript.recordingID == recording.id {
                    MeetingMinutesView(recording: recording, model: model)
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 110)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .searchable(text: $transcriptSearch, placement: .toolbar, prompt: "Search Transcript")
        .toolbar {
            detailToolbar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !recording.audioAssets.isEmpty || playback.errorMessage != nil {
                FloatingPlaybackBar(playback: playback)
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
            "Delete Recording?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                Task { await model.deleteRecording(recording.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the managed audio, transcript, and minutes for \"\(recording.title)\" from Bardo.")
        }
    }

    private var recordingHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(recording.title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                    .textSelection(.enabled)

                if recording.processingState == .processing {
                    ProgressView()
                        .controlSize(.small)
                } else if recording.processingState == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .help("This recording needs attention")
                }
            }

            HStack(spacing: 7) {
                Text(recording.createdAt, format: .dateTime.month(.wide).day().year().hour().minute())
                Text("·")
                Text(LibraryFormatting.source(recording.sources))
                Text("·")
                Text(LibraryFormatting.duration(recording.duration))
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    if model.selection == recording.id, playback.isPlaying {
                        playback.pause()
                    } else {
                        Task { await model.playRecording(recording.id) }
                    }
                } label: {
                    Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(!RecordingActionPolicy.allows(.playPause, for: recording) || model.isTranscribing || model.isDiarizing)

                Divider()

                Button {
                    isRenamePresented = true
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }

                Button {
                    Task { await model.copyManagedLocation(recording.id) }
                } label: {
                    Label("Copy Location", systemImage: "doc.on.doc")
                }

                Button {
                    revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                Divider()

                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Delete Recording", systemImage: "trash")
                }
                .disabled(model.isTranscribing || model.isDiarizing || model.isGeneratingMeetingMinutes)
            } label: {
                Label("Recording Actions", systemImage: "ellipsis.circle")
            }
            .help("Recording actions")

            if let transcript = model.transcript,
               transcript.recordingID == recording.id {
                Button {
                    copyTranscript(transcript)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .disabled(transcript.text.isEmpty)
                .help("Copy transcript")

                Menu {
                    Button {
                        if transcript.diarizationMetadata != nil, transcript.hasNamedSpeakers {
                            pendingReplacementAction = .rediarize
                        } else {
                            model.beginDiarization()
                        }
                    } label: {
                        Label(
                            transcript.diarizationMetadata == nil ? "Identify Speakers" : "Identify Speakers Again",
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
                        Label("Transcribe Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)
                } label: {
                    Label("Transcript Actions", systemImage: "ellipsis")
                }
                .help("Transcript actions")
            }

            Button {
                isInspectorPresented.toggle()
            } label: {
                Label("Recording Info", systemImage: "sidebar.right")
            }
            .help(isInspectorPresented ? "Hide recording info" : "Show recording info")
        }
    }

    private func copyTranscript(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(transcript.text, forType: .string) {
            model.reportRecordingActionFeedback("Transcript copied")
        }
    }

    private func revealInFinder() {
        Task {
            guard let location = try? await model.managedLocation(for: recording.id) else {
                model.reportRecordingActionError("Bardo could not locate the managed recording folder.")
                return
            }
            let target = FileManager.default.fileExists(atPath: location.path)
                ? location
                : location.deletingLastPathComponent()
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}
