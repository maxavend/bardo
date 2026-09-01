import AppKit
import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var transcriptSearch = ""
    @State private var searchMatchIndex = 0
    @State private var editor: TranscriptEditorState?
    @State private var pendingReplacementAction: TranscriptReplacementAction?
    @State private var isInspectorPresented = false
    @State private var copyFeedback: CopyFeedback?
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool
    @State private var isDeletePresented = false
    @State private var pendingScrollBlockID: TranscriptReadingBlock.ID?
    @State private var isSpeakerNamingPresented = false
    @State private var pendingSpeakerNamingDiarization: PendingSpeakerNamingDiarization?

    var body: some View {
        detailChrome
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("")
            .overlay(alignment: .topTrailing) {
                if let copyFeedback {
                    copyFeedbackView(copyFeedback)
                        .padding(.top, 14)
                        .padding(.trailing, 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: copyFeedback)
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
                RecordingInspector(
                    recording: recording,
                    transcript: selectedTranscript,
                    canEditSpeakers: !model.isTranscribing && !model.isDiarizing,
                    onRenameSpeaker: { speakerID, name in
                        Task { await model.renameSpeaker(speakerID, to: name) }
                    }
                )
            }
            .onChange(of: transcriptSearch) { _, _ in
                synchronizeSearchSelection(scroll: true)
            }
            .onChange(of: model.isDiarizing) { wasDiarizing, isDiarizing in
                handleDiarizationCompletion(
                    wasDiarizing: wasDiarizing,
                    isDiarizing: isDiarizing
                )
            }
            .onChange(of: recording.id) { _, _ in
                transcriptSearch = ""
                searchMatchIndex = 0
                editor = nil
                pendingReplacementAction = nil
                copyFeedback = nil
                isEditingTitle = false
                isDeletePresented = false
                pendingScrollBlockID = nil
                isSpeakerNamingPresented = false
                pendingSpeakerNamingDiarization = nil
            }
            .sheet(isPresented: $isSpeakerNamingPresented) {
                if let transcript = selectedTranscript, transcript.diarizationMetadata != nil {
                    SpeakerNamingSheet(
                        transcript: transcript,
                        audioURL: playback.loadedAudioURL,
                        onSave: { names in
                            isSpeakerNamingPresented = false
                            persistSpeakerNames(names, from: transcript)
                        },
                        onSkip: {
                            isSpeakerNamingPresented = false
                        }
                    )
                }
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
                            beginDiarizationForSpeakerNaming()
                        }
                    },
                    secondaryButton: .cancel()
                )
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

    @ViewBuilder
    private var detailChrome: some View {
        if MacOSUICompatibility.usesNativeToolbar {
            detailScrollContent
                .searchable(text: $transcriptSearch, placement: .toolbar, prompt: "Search Transcript")
                .toolbar {
                    detailToolbar
                }
        } else {
            detailScrollContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    detailCompatibilityBar
                }
        }
    }

    private var detailScrollContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    recordingHeader
                        .frame(maxWidth: BardoDesignMetrics.detailChromeWidth, alignment: .leading)

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

                            // Keep auto-follow outside the AppKit layout update that changed the
                            // active row. Search navigation deliberately uses the same deferred path.
                            pendingScrollBlockID = blockID
                        }
                    )
                    .frame(maxWidth: BardoDesignMetrics.readableTranscriptWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, BardoDesignMetrics.detailHorizontalPadding)
                .padding(.top, BardoDesignMetrics.detailTopPadding)
                .padding(.bottom, 110)
            }
            .task(id: pendingScrollBlockID) {
                guard let blockID = pendingScrollBlockID else { return }

                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled,
                      pendingScrollBlockID == blockID else {
                    return
                }

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(blockID, anchor: .center)
                }
            }
        }
    }

    private var recordingHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isEditingTitle {
                    TextField("Recording Name", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .focused($titleFieldFocused)
                        .onSubmit(commitTitleRename)
                        .frame(maxWidth: 620)

                    Button(action: commitTitleRename) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderless)
                    .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Save")

                    Button(action: cancelTitleRename) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel")
                } else {
                    Text(recording.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Button(action: beginTitleRename) {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rename")
                }

                if recording.processingState == .processing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(LibraryFormatting.state(recording.processingState))
                } else if recording.processingState == .failed || recording.processingState == .partial {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .help(recording.processingState == .partial ? "This transcript is partial" : "This recording needs attention")
                        .accessibilityLabel(LibraryFormatting.state(recording.processingState))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    Text(recording.createdAt, format: .dateTime.month(.wide).day().year().hour().minute())
                    Text("·")
                    Text(LibraryFormatting.source(recording.sources))
                    Text("·")
                    Text(LibraryFormatting.duration(recording.duration))
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.createdAt, format: .dateTime.month(.wide).day().year().hour().minute())
                    Text("\(LibraryFormatting.source(recording.sources)) · \(LibraryFormatting.duration(recording.duration))")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if recording.processingState == .partial {
                Text("Partial transcript — retry to process the full recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if !trimmedSearch.isEmpty {
            ToolbarItem(id: "bardo.detail.search.status", placement: .automatic) {
                Text(searchResultLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ToolbarItem(id: "bardo.detail.search.previous", placement: .automatic) {
                Button {
                    moveSearch(by: -1)
                } label: {
                    Label("Previous Match", systemImage: "chevron.up")
                }
                .disabled(searchMatchIDs.isEmpty)
                .help("Previous Match")
            }

            ToolbarItem(id: "bardo.detail.search.next", placement: .automatic) {
                Button {
                    moveSearch(by: 1)
                } label: {
                    Label("Next Match", systemImage: "chevron.down")
                }
                .disabled(searchMatchIDs.isEmpty)
                .help("Next Match")
            }
        }

        if let transcript = selectedTranscript {
            ToolbarItem(id: "bardo.detail.copy", placement: .primaryAction) {
                copyTranscriptMenu(transcript)
            }

            ToolbarItem(id: "bardo.detail.speakers", placement: .primaryAction) {
                speakersMenu(transcript)
            }
        }

        ToolbarItem(id: "bardo.detail.info", placement: .primaryAction) {
            recordingInfoButton
        }

        ToolbarItem(id: "bardo.detail.more", placement: .primaryAction) {
            moreActionsMenu
        }
    }

    private var detailCompatibilityBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search Transcript", text: $transcriptSearch)
                    .textFieldStyle(.plain)

                if !trimmedSearch.isEmpty {
                    Text(searchResultLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Button {
                        moveSearch(by: -1)
                    } label: {
                        Label("Previous Match", systemImage: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .disabled(searchMatchIDs.isEmpty)
                    .help("Previous Match")

                    Button {
                        moveSearch(by: 1)
                    } label: {
                        Label("Next Match", systemImage: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .disabled(searchMatchIDs.isEmpty)
                    .help("Next Match")

                    Button {
                        transcriptSearch = ""
                    } label: {
                        Label("Clear Search", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer(minLength: 12)

            if let transcript = selectedTranscript {
                copyTranscriptMenu(transcript)
                    .labelStyle(.iconOnly)
                speakersMenu(transcript)
                    .labelStyle(.iconOnly)
            }

            recordingInfoButton
                .labelStyle(.iconOnly)
            moreActionsMenu
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func copyTranscriptMenu(_ transcript: Transcript) -> some View {
        Menu {
            Button("Copy Transcript") {
                copyTranscript(transcript, style: .automatic)
            }

            if transcript.diarizationMetadata != nil {
                Button("Copy Without Speakers") {
                    copyTranscript(transcript, style: .withoutSpeakers)
                }
            }

            Button("Copy With Timestamps") {
                copyTranscript(transcript, style: .withTimestamps)
            }
        } label: {
            Label("Copy Transcript", systemImage: "doc.on.doc")
        }
        .disabled(transcript.text.isEmpty)
        .help("Copy Transcript")
    }

    private func speakersMenu(_ transcript: Transcript) -> some View {
        Menu {
            if transcript.diarizationMetadata != nil {
                Button {
                    presentSpeakerNaming()
                } label: {
                    Label("Manage Speakers", systemImage: "person.text.rectangle")
                }
                .disabled(transcript.speakers.isEmpty)

                Divider()
            }

            identifySpeakersAction(transcript)
        } label: {
            Label("Speakers", systemImage: "person.2")
        }
        .help("Speakers")
    }

    private var recordingInfoButton: some View {
        Button {
            isInspectorPresented.toggle()
        } label: {
            Label("Recording Info", systemImage: "sidebar.trailing")
        }
        .help(isInspectorPresented ? "Hide recording info" : "Show recording info")
    }

    private var moreActionsMenu: some View {
        Menu {
            if selectedTranscript != nil {
                Button {
                    if selectedTranscript?.hasManualChanges == true {
                        pendingReplacementAction = .retranscribe
                    } else {
                        model.beginTranscription()
                    }
                } label: {
                    Label("Transcribe Again", systemImage: "arrow.clockwise")
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)

                Divider()
            }

            Button(action: beginTitleRename) {
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

    @ViewBuilder
    private func identifySpeakersAction(_ transcript: Transcript) -> some View {
        Button {
            if transcript.diarizationMetadata != nil, transcript.hasNamedSpeakers {
                pendingReplacementAction = .rediarize
            } else {
                beginDiarizationForSpeakerNaming()
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
    }

    private var selectedTranscript: Transcript? {
        guard let transcript = model.transcript, transcript.recordingID == recording.id else { return nil }
        return transcript
    }

    private func beginDiarizationForSpeakerNaming() {
        pendingSpeakerNamingDiarization = PendingSpeakerNamingDiarization(
            recordingID: recording.id,
            baselineDiarizationCreatedAt: selectedTranscript?.diarizationMetadata?.createdAt
        )
        model.beginDiarization()
    }

    private func handleDiarizationCompletion(wasDiarizing: Bool, isDiarizing: Bool) {
        guard wasDiarizing,
              !isDiarizing,
              let pending = pendingSpeakerNamingDiarization else {
            return
        }
        pendingSpeakerNamingDiarization = nil

        guard pending.recordingID == recording.id,
              model.diarizationErrorMessage == nil,
              let transcript = selectedTranscript,
              let diarization = transcript.diarizationMetadata,
              diarization.createdAt != pending.baselineDiarizationCreatedAt,
              !transcript.speakers.isEmpty else {
            return
        }

        presentSpeakerNaming()
    }

    private func presentSpeakerNaming() {
        guard selectedTranscript?.diarizationMetadata != nil else { return }
        if playback.isPlaying {
            playback.pause()
        }
        isSpeakerNamingPresented = true
    }

    private func persistSpeakerNames(_ names: [Speaker.ID: String], from transcript: Transcript) {
        Task {
            for speaker in transcript.speakers {
                let proposed = names[speaker.id]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let existing = speaker.name?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard proposed != existing else { continue }
                await model.renameSpeaker(speaker.id, to: proposed)
            }
        }
    }

    private var trimmedSearch: String {
        transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchMatchIDs: [TranscriptReadingBlock.ID] {
        guard let transcript = selectedTranscript, !trimmedSearch.isEmpty else { return [] }
        let blocks = TranscriptReadingBlockBuilder.blocks(from: transcript.segments)
        return blocks.compactMap { block in
            let speakerText: String
            if transcript.speakers.isEmpty {
                speakerText = ""
            } else {
                speakerText = TranscriptExportFormatter.speakerLabel(for: block, in: transcript)
            }
            return block.text.localizedCaseInsensitiveContains(trimmedSearch)
                || speakerText.localizedCaseInsensitiveContains(trimmedSearch)
                ? block.id
                : nil
        }
    }

    private var searchResultLabel: String {
        let matches = searchMatchIDs
        guard !matches.isEmpty else { return "0 of 0" }
        return "\(min(searchMatchIndex + 1, matches.count)) of \(matches.count)"
    }

    private func synchronizeSearchSelection(scroll: Bool) {
        let matches = searchMatchIDs
        guard !matches.isEmpty else {
            searchMatchIndex = 0
            return
        }
        searchMatchIndex = min(max(0, searchMatchIndex), matches.count - 1)
        if scroll {
            pendingScrollBlockID = matches[searchMatchIndex]
        }
    }

    private func moveSearch(by delta: Int) {
        let matches = searchMatchIDs
        guard !matches.isEmpty else { return }
        let count = matches.count
        searchMatchIndex = (searchMatchIndex + delta + count) % count
        pendingScrollBlockID = matches[searchMatchIndex]
    }

    private func beginTitleRename() {
        titleDraft = recording.title
        isEditingTitle = true
        Task { @MainActor in
            await Task.yield()
            titleFieldFocused = true
        }
    }

    private func cancelTitleRename() {
        titleFieldFocused = false
        titleDraft = recording.title
        isEditingTitle = false
    }

    private func commitTitleRename() {
        let proposed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return }
        Task {
            if await model.renameRecording(id: recording.id, to: proposed) {
                isEditingTitle = false
                titleFieldFocused = false
            }
        }
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

    private func copyTranscript(_ transcript: Transcript, style: TranscriptExportStyle) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let exported = TranscriptExportFormatter.string(from: transcript, style: style)
        copyFeedback = pasteboard.setString(exported, forType: .string) ? .copied : .failed
    }
}

private struct PendingSpeakerNamingDiarization: Equatable {
    let recordingID: Recording.ID
    let baselineDiarizationCreatedAt: Date?
}

private enum CopyFeedback: Hashable {
    case copied
    case failed
}
