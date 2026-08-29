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
    @State private var copyFeedback: CopyFeedback?
    @State private var isRenamePresented = false
    @State private var renameTitle = ""
    @State private var isDeletePresented = false
    @State private var pendingFollowBlockID: TranscriptReadingBlock.ID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    recordingHeader

                    TranscriptContentView(
                        recording: recording,
                        model: model,
                        playback: playback,
                        searchText: $transcriptSearch,
                        editor: $editor,
                        onPlaybackBlockChange: { blockID in
                            guard let blockID,
                                  transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                return
                            }

                            // Never mutate AppKit's scroll/layout hierarchy from the same update
                            // cycle that changed the active transcript row. The deferred task below
                            // performs one stable, non-animated scroll after layout has settled.
                            pendingFollowBlockID = blockID
                        }
                    )
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 34)
                .padding(.bottom, 110)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .task(id: pendingFollowBlockID) {
                guard let blockID = pendingFollowBlockID else { return }

                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled,
                      pendingFollowBlockID == blockID,
                      transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(blockID, anchor: .center)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .searchable(text: $transcriptSearch, placement: .toolbar, prompt: "Search Transcript")
        .toolbar {
            detailToolbar
        }
        .overlay(alignment: .topTrailing) {
            if let copyFeedback {
                copyFeedbackView(copyFeedback)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: copyFeedback)
        .task(id: copyFeedback) {
            guard copyFeedback != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled {
                copyFeedback = nil
            }
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
            copyFeedback = nil
            isRenamePresented = false
            isDeletePresented = false
            pendingFollowBlockID = nil
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
        .alert("Rename Recording", isPresented: $isRenamePresented) {
            TextField("Recording Name", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task {
                    _ = await model.renameRecording(id: recording.id, to: renameTitle)
                }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name you’ll recognize later.")
        }
        .alert("Delete Recording?", isPresented: $isDeletePresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    _ = await model.deleteRecording(id: recording.id)
                }
            }
        } message: {
            Text(deleteMessage)
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
                } else if recording.processingState == .failed || recording.processingState == .partial {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .help(recording.processingState == .partial ? "This transcript is partial" : "This recording needs attention")
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

            if recording.processingState == .partial {
                Label("Partial transcript — retry to process the full recording", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let transcript = selectedTranscript {
                Button {
                    copyTranscript(transcript)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .disabled(transcript.text.isEmpty)
                .help("Copy transcript")
            }

            Button {
                isInspectorPresented.toggle()
            } label: {
                Label("Recording Info", systemImage: "info.circle")
            }
            .help(isInspectorPresented ? "Hide recording info" : "Show recording info")

            Menu {
                transcriptMenuActions

                if selectedTranscript != nil {
                    Divider()
                }

                Button {
                    renameTitle = recording.title
                    isRenamePresented = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    isDeletePresented = true
                } label: {
                    Label("Delete Recording", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More recording actions")
        }
    }

    @ViewBuilder
    private var transcriptMenuActions: some View {
        if let transcript = selectedTranscript {
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
            .disabled(
                !transcript.isComplete
                    || recording.audioAssets.isEmpty
                    || model.isDiarizing
                    || model.isTranscribing
            )

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
        }
    }

    private var selectedTranscript: Transcript? {
        guard let transcript = model.transcript, transcript.recordingID == recording.id else { return nil }
        return transcript
    }

    private var deleteMessage: String {
        if model.isProcessing(recordingID: recording.id) {
            return "Bardo will stop the current processing task, then permanently remove this recording and its transcript from this Mac."
        }
        return "“\(recording.title)” and its transcript will be permanently removed from this Mac."
    }

    @ViewBuilder
    private func copyFeedbackView(_ feedback: CopyFeedback) -> some View {
        Label(
            feedback == .copied ? "Transcript Copied" : "Couldn’t Copy Transcript",
            systemImage: feedback == .copied ? "checkmark" : "exclamationmark.triangle"
        )
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .bardoGlassSurface(cornerRadius: 14)
        .accessibilityAddTraits(.isStaticText)
    }

    private func copyTranscript(_ transcript: Transcript) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copyFeedback = pasteboard.setString(transcript.text, forType: .string) ? .copied : .failed
    }
}

private enum CopyFeedback: Hashable {
    case copied
    case failed
}
