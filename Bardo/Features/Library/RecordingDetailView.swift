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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                recordingHeader

                TranscriptContentView(
                    recording: recording,
                    model: model,
                    playback: playback,
                    searchText: $transcriptSearch,
                    editor: $editor
                )
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
        NSPasteboard.general.setString(transcript.text, forType: .string)
    }
}
