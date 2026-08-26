import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var isFileImporterPresented = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Library")
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
                .toolbar {
                    ToolbarItem {
                        Button {
                            isFileImporterPresented = true
                        } label: {
                            Label("Import Audio", systemImage: "square.and.arrow.down")
                        }
                        .keyboardShortcut("o", modifiers: .command)
                        .help("Import audio…")
                        .disabled(model.isImporting || model.isTranscribing || model.isDiarizing)
                    }

                    ToolbarItem {
                        Button {
                            Task { await model.reload() }
                        } label: {
                            Label("Reload Library", systemImage: "arrow.clockwise")
                        }
                        .help("Reload Library")
                        .disabled(model.isLoading || model.isImporting || model.isTranscribing || model.isDiarizing)
                    }
                }
        } detail: {
            detail
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
        .onDisappear {
            model.cancelTranscription()
            model.cancelDiarization()
            model.stopPlayback()
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if model.isLoading && model.recordings.isEmpty {
            ProgressView("Loading Library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isImporting && model.recordings.isEmpty {
            ProgressView("Importing Audio…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage, model.recordings.isEmpty {
            ContentUnavailableView {
                Label("Library Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await model.reload() }
                }
            }
        } else if model.recordings.isEmpty && !model.issues.isEmpty {
            ContentUnavailableView {
                Label("Library Needs Recovery", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(model.issues.count) stored item\(model.issues.count == 1 ? "" : "s") could not be loaded. Bardo left them untouched.")
            } actions: {
                Button("Reload") {
                    Task { await model.reload() }
                }
            }
        } else if model.recordings.isEmpty {
            ContentUnavailableView {
                Label("No Recordings", systemImage: "waveform")
            } description: {
                Text("Record a conversation, import an audio file, or drop audio into this window.")
            } actions: {
                Button("Import Audio…") {
                    isFileImporterPresented = true
                }
            }
        } else {
            List(selection: $model.selection) {
                if model.isImporting {
                    Section {
                        Label {
                            Text("Importing audio…")
                        } icon: {
                            ProgressView()
                                .controlSize(.small)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section("Library Error") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.issues.isEmpty {
                    Section("Recovery") {
                        ForEach(model.issues) { issue in
                            Label(issue.message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Recordings") {
                    ForEach(model.recordings) { recording in
                        RecordingRow(recording: recording)
                            .tag(recording.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let recording = model.selectedRecording {
            RecordingDetail(
                recording: recording,
                model: model,
                playback: model.playback
            )
        } else {
            ContentUnavailableView {
                Label("Choose a Recording", systemImage: "waveform")
            } description: {
                Text("Select an item in the Library to play, transcribe, and review it.")
            }
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sourceSymbol(recording.sources))
                .font(.body)
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(recording.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(recording.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 5) {
                    Text(durationText(recording.duration))
                    Text("•")
                    Text(sourceText(recording.sources))
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Label(stateText(recording.processingState), systemImage: stateSymbol(recording.processingState))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingDetail: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @State private var transcriptSearch = ""
    @State private var editor: TranscriptEditorState?
    @State private var pendingReplacementAction: TranscriptReplacementAction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                recordingHeader
                playbackSection
                transcriptSection
                recordingDetails
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(recording.title)
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
                    case .rediariize:
                        model.beginDiarization()
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var recordingHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recording.title)
                .font(.title.weight(.semibold))
                .textSelection(.enabled)

            HStack(spacing: 14) {
                Label(recording.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(durationText(recording.duration), systemImage: "clock")
                Label(sourceText(recording.sources), systemImage: sourceSymbol(recording.sources))
                Label(stateText(recording.processingState), systemImage: stateSymbol(recording.processingState))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private var playbackSection: some View {
        GroupBox {
            if recording.audioAssets.isEmpty {
                ContentUnavailableView(
                    "No Managed Audio",
                    systemImage: "waveform.slash",
                    description: Text("This recording has no managed audio available for playback.")
                )
                .frame(minHeight: 110)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage = playback.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            playback.togglePlayback()
                        } label: {
                            Label(
                                playback.isPlaying ? "Pause" : "Play",
                                systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!playback.isLoaded)
                        .keyboardShortcut(.space, modifiers: [])

                        Slider(
                            value: Binding(
                                get: { playback.position },
                                set: { playback.seek(to: $0) }
                            ),
                            in: 0...max(playback.duration, 0.01)
                        )
                        .disabled(!playback.isLoaded)
                        .accessibilityLabel("Playback position")

                        Text("\(durationText(playback.position)) / \(durationText(playback.duration))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 92, alignment: .trailing)
                    }
                }
                .padding(.vertical, 4)
            }
        } label: {
            Label("Playback", systemImage: "play.circle")
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        GroupBox {
            if model.isTranscribing {
                transcriptionProgressView
            } else if let transcript = model.transcript,
                      transcript.recordingID == recording.id {
                VStack(alignment: .leading, spacing: 16) {
                    transcriptErrors

                    if model.isDiarizing, model.diarizationRecordingID == recording.id {
                        diarizationProgressView
                    } else {
                        transcriptControls(transcript)
                        transcriptConversation(transcript)
                        transcriptDetails(transcript)
                    }
                }
                .padding(.vertical, 4)
            } else {
                emptyTranscriptView
            }
        } label: {
            Label("Transcript", systemImage: "text.bubble")
        }
    }

    private var transcriptionProgressView: some View {
        let progress = model.transcriptionProgress
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(transcriptionStageText(progress?.stage))
                        .font(.headline)
                    Text(transcriptionStageDetail(progress))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if shouldShowDeterminateTranscriptionProgress(progress) {
                ProgressView(value: progress?.fractionCompleted ?? 0)
            }

            HStack {
                Label("Audio stays on this Mac", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelTranscription()
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var emptyTranscriptView: some View {
        VStack(spacing: 14) {
            ContentUnavailableView {
                Label(
                    recording.processingState == .failed ? "Transcription Needs Attention" : "No Transcript Yet",
                    systemImage: recording.processingState == .failed ? "exclamationmark.bubble" : "text.bubble"
                )
            } description: {
                Text("Create a private, on-device transcript with WhisperKit. The model is prepared locally the first time you use it.")
            } actions: {
                Button(recording.processingState == .failed ? "Retry Transcription" : "Transcribe") {
                    model.beginTranscription()
                }
                .buttonStyle(.borderedProminent)
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing)
            }

            if let error = model.transcriptErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var transcriptErrors: some View {
        if let error = model.transcriptErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let error = model.diarizationErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let error = model.transcriptEditErrorMessage {
            HStack(alignment: .firstTextBaseline) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") {
                    model.clearTranscriptEditError()
                }
                .buttonStyle(.link)
            }
        }
    }

    private var diarizationProgressView: some View {
        let progress = model.diarizationProgress
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(diarizationStageText(progress?.stage))
                        .font(.headline)
                    Text(diarizationStageDetail(progress?.stage))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress, progress.fractionCompleted > 0, progress.fractionCompleted < 1 {
                ProgressView(value: progress.fractionCompleted)
            }

            HStack {
                Label("Speaker identification stays on this Mac", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelDiarization()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func transcriptControls(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label(transcript.languageCode ?? "Auto", systemImage: "captions.bubble")

                if transcript.diarizationMetadata != nil {
                    Label(
                        "\(transcript.speakers.count) speaker\(transcript.speakers.count == 1 ? "" : "s")",
                        systemImage: "person.2"
                    )
                }

                if transcript.hasManualChanges {
                    Label("Edited", systemImage: "pencil.line")
                }

                Spacer()

                Button {
                    copyTranscript(transcript)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(transcript.text.isEmpty)
                .help("Copy Transcript")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            TextField("Search Transcript", text: $transcriptSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search transcript")

            HStack(spacing: 8) {
                Button {
                    if transcript.diarizationMetadata != nil, transcript.hasNamedSpeakers {
                        pendingReplacementAction = .rediariize
                    } else {
                        model.beginDiarization()
                    }
                } label: {
                    Label(
                        transcript.diarizationMetadata == nil ? "Identify Speakers" : "Identify Again",
                        systemImage: "person.2.wave.2"
                    )
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing)

                Button {
                    if transcript.hasManualChanges {
                        pendingReplacementAction = .retranscribe
                    } else {
                        model.beginTranscription()
                    }
                } label: {
                    Label("Transcribe Again", systemImage: "arrow.clockwise")
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing)

                Spacer()

                if !transcriptSearch.isEmpty {
                    Button("Clear Search") {
                        transcriptSearch = ""
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptConversation(_ transcript: Transcript) -> some View {
        let segments = filteredSegments(in: transcript)

        if transcript.segments.isEmpty {
            ContentUnavailableView(
                "Empty Transcript",
                systemImage: "text.bubble",
                description: Text("WhisperKit finished without readable transcript segments.")
            )
        } else if segments.isEmpty {
            ContentUnavailableView.search(text: transcriptSearch)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    transcriptTurn(segment, in: transcript)
                        .padding(.vertical, 14)

                    if index < segments.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func transcriptTurn(_ segment: TranscriptSegment, in transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let speakerID = segment.speakerID,
                   transcript.speakers.contains(where: { $0.id == speakerID }) {
                    Button(speakerLabel(for: segment, in: transcript)) {
                        editor = speakerEditorState(speakerID: speakerID, transcript: transcript)
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .help("Rename this speaker")
                } else if transcript.speakers.isEmpty {
                    Text("Transcript")
                        .font(.callout.weight(.semibold))
                } else {
                    Text("Unassigned Speaker")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    playback.seek(to: segment.startTime)
                } label: {
                    Label(durationText(segment.startTime), systemImage: "play.circle")
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!playback.isLoaded)
                .help("Play from \(durationText(segment.startTime))")

                Button {
                    editor = .segment(segment)
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isTranscribing || model.isDiarizing)
                .help("Edit transcript text")
            }

            Text(segment.displayText)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if segment.editedText != nil {
                Label("Edited", systemImage: "pencil.line")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transcriptDetails(_ transcript: Transcript) -> some View {
        DisclosureGroup("Transcript Details") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Language", value: transcript.languageCode ?? "Auto-detected")
                LabeledContent("Model", value: transcript.metadata.modelID)
                LabeledContent("Engine", value: "\(transcript.metadata.engine) \(transcript.metadata.engineVersion)")

                if let diarization = transcript.diarizationMetadata {
                    Divider()
                    LabeledContent("Speakers", value: String(transcript.speakers.count))
                    LabeledContent("Speaker Engine", value: "\(diarization.engine) \(diarization.engineVersion)")
                    LabeledContent("Speaker Model", value: diarization.modelID)
                }
            }
            .font(.callout)
            .padding(.top, 8)
        }
    }

    private var recordingDetails: some View {
        DisclosureGroup("Recording Details") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Created") {
                    Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                LabeledContent("Source", value: sourceText(recording.sources))
                LabeledContent("Duration", value: durationText(recording.duration))
                LabeledContent("Status", value: stateText(recording.processingState))

                if let asset = recording.audioAssets.first {
                    Divider()
                    LabeledContent("Original File", value: asset.originalFileName)
                    LabeledContent("Codec", value: asset.metadata.codec)
                    LabeledContent("Sample Rate", value: sampleRateText(asset.metadata.sampleRate))
                    LabeledContent("Channels", value: String(asset.metadata.channelCount))
                }

                Divider()
                LabeledContent("Recording ID") {
                    Text(recording.id.uuidString)
                        .textSelection(.enabled)
                        .monospaced()
                }
            }
            .font(.callout)
            .padding(.top, 8)
        }
        .foregroundStyle(.secondary)
    }

    private func filteredSegments(in transcript: Transcript) -> [TranscriptSegment] {
        let query = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return transcript.segments }

        return transcript.segments.filter { segment in
            segment.displayText.localizedCaseInsensitiveContains(query)
                || speakerLabel(for: segment, in: transcript).localizedCaseInsensitiveContains(query)
        }
    }

    private func speakerEditorState(speakerID: Speaker.ID, transcript: Transcript) -> TranscriptEditorState? {
        guard let speaker = transcript.speakers.first(where: { $0.id == speakerID }) else { return nil }
        let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) ?? 0
        return .speaker(speaker, fallbackName: "Speaker \(index + 1)")
    }

    private func speakerLabel(for segment: TranscriptSegment, in transcript: Transcript) -> String {
        guard let speakerID = segment.speakerID,
              let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else {
            return transcript.speakers.isEmpty ? "Transcript" : "Unassigned Speaker"
        }

        let speaker = transcript.speakers[index]
        if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Speaker \(index + 1)"
    }

    private func copyTranscript(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.text, forType: .string)
    }
}

private enum TranscriptReplacementAction: String, Identifiable {
    case retranscribe
    case rediariize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .retranscribe: "Replace Manual Transcript Changes?"
        case .rediariize: "Replace Speaker Names?"
        }
    }

    var message: String {
        switch self {
        case .retranscribe:
            "Transcribing again creates a new transcript and removes manual text corrections and speaker names from the current transcript."
        case .rediariize:
            "Identifying speakers again creates new speaker clusters. Existing speaker names will be removed because the new clusters may represent different people. Manual text corrections are preserved."
        }
    }

    var confirmLabel: String {
        switch self {
        case .retranscribe: "Transcribe Again"
        case .rediariize: "Identify Speakers Again"
        }
    }
}

private struct TranscriptEditorState: Identifiable {
    enum Kind {
        case speaker(Speaker.ID)
        case segment(TranscriptSegment.ID)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let initialValue: String
    let prompt: String
    let canRestore: Bool
    let isMultiline: Bool

    static func speaker(_ speaker: Speaker, fallbackName: String) -> TranscriptEditorState {
        TranscriptEditorState(
            kind: .speaker(speaker.id),
            title: "Name Speaker",
            initialValue: speaker.name ?? "",
            prompt: "Give \(fallbackName) a name. Leave it blank to restore the automatic label.",
            canRestore: false,
            isMultiline: false
        )
    }

    static func segment(_ segment: TranscriptSegment) -> TranscriptEditorState {
        TranscriptEditorState(
            kind: .segment(segment.id),
            title: "Edit Transcript",
            initialValue: segment.displayText,
            prompt: "Correct the readable transcript while preserving WhisperKit's original timing evidence.",
            canRestore: segment.editedText != nil,
            isMultiline: true
        )
    }
}

private struct TranscriptEditorSheet: View {
    let state: TranscriptEditorState
    let onSave: (String) -> Void
    let onRestore: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var value: String

    init(
        state: TranscriptEditorState,
        onSave: @escaping (String) -> Void,
        onRestore: (() -> Void)?
    ) {
        self.state = state
        self.onSave = onSave
        self.onRestore = onRestore
        _value = State(initialValue: state.initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.title2.weight(.semibold))
                Text(state.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if state.isMultiline {
                TextEditor(text: $value)
                    .font(.body)
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                TextField("Speaker Name", text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if let onRestore {
                    Button("Restore Original", role: .destructive) {
                        onRestore()
                    }
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(value)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.isMultiline && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: state.isMultiline ? 320 : 190)
    }
}

private func transcriptionStageText(_ stage: TranscriptionStage?) -> String {
    switch stage {
    case .preparingModel: "Preparing Whisper Model"
    case .loadingModel: "Loading Whisper Model"
    case .transcribing: "Transcribing Audio"
    case .saving: "Saving Transcript"
    case nil: "Preparing Transcription"
    }
}

private func transcriptionStageDetail(_ progress: TranscriptionProgressSnapshot?) -> String {
    switch progress?.stage {
    case .preparingModel:
        "Bardo is preparing the local Whisper resources. The first run can take longer while model files are downloaded."
    case .loadingModel:
        "WhisperKit is loading and prewarming the model on this Mac. This stage may take a moment and doesn't expose a reliable percentage."
    case .transcribing:
        "Bardo is processing the recording locally. Progress advances as audio chunks finish."
    case .saving:
        "The finished transcript is being saved to your local Bardo library."
    case nil:
        "Bardo is getting the local transcription pipeline ready."
    }
}

private func shouldShowDeterminateTranscriptionProgress(_ progress: TranscriptionProgressSnapshot?) -> Bool {
    guard let progress else { return false }
    switch progress.stage {
    case .preparingModel, .transcribing:
        return progress.fractionCompleted > 0 && progress.fractionCompleted < 1
    case .loadingModel, .saving:
        return false
    }
}

private func diarizationStageText(_ stage: DiarizationStage?) -> String {
    switch stage {
    case .preparingModel: "Preparing Speaker Model"
    case .loadingModel: "Loading Speaker Model"
    case .diarizing: "Identifying Speakers"
    case .saving: "Saving Speaker Labels"
    case nil: "Preparing Speaker Identification"
    }
}

private func diarizationStageDetail(_ stage: DiarizationStage?) -> String {
    switch stage {
    case .preparingModel:
        "Bardo is preparing SpeakerKit resources locally. The first run can take longer while model files are downloaded."
    case .loadingModel:
        "SpeakerKit is loading the local diarization pipeline."
    case .diarizing:
        "Bardo is analyzing the full recording to identify distinct voices."
    case .saving:
        "Speaker labels are being written into the existing transcript."
    case nil:
        "Bardo is getting the local speaker-identification pipeline ready."
    }
}

private func durationText(_ duration: TimeInterval?) -> String {
    guard let duration else { return "Unknown" }
    return durationText(duration)
}

private func durationText(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration.rounded()))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

private func sampleRateText(_ sampleRate: Double) -> String {
    if sampleRate >= 1_000 {
        return String(format: "%.1f kHz", sampleRate / 1_000)
    }
    return String(format: "%.0f Hz", sampleRate)
}

private func sourceText(_ sources: Set<AudioSource>) -> String {
    guard !sources.isEmpty else { return "Unknown source" }
    return sources
        .sorted { $0.rawValue < $1.rawValue }
        .map { source in
            switch source {
            case .microphone: "Microphone"
            case .systemAudio: "System Audio"
            case .importedFile: "Imported File"
            }
        }
        .joined(separator: " + ")
}

private func sourceSymbol(_ sources: Set<AudioSource>) -> String {
    if sources.contains(.systemAudio), sources.contains(.microphone) {
        return "person.wave.2"
    }
    if sources.contains(.systemAudio) {
        return "display"
    }
    if sources.contains(.microphone) {
        return "mic"
    }
    if sources.contains(.importedFile) {
        return "waveform.badge.plus"
    }
    return "waveform"
}

private func stateText(_ state: ProcessingState) -> String {
    switch state {
    case .pending: "Ready"
    case .processing: "Processing"
    case .completed: "Transcribed"
    case .failed: "Needs Attention"
    }
}

private func stateSymbol(_ state: ProcessingState) -> String {
    switch state {
    case .pending: "circle"
    case .processing: "clock.arrow.circlepath"
    case .completed: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
}