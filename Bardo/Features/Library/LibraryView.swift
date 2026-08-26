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
                .toolbar {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Import Audio", systemImage: "plus")
                    }
                    .disabled(model.isImporting || model.isTranscribing || model.isDiarizing)

                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("Reload Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading || model.isImporting || model.isTranscribing || model.isDiarizing)
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
                Text("Import a compatible audio file or drop one into this window.")
            } actions: {
                Button("Import Audio") {
                    isFileImporterPresented = true
                }
            }
        } else {
            List(selection: $model.selection) {
                if model.isImporting {
                    Section {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing audio…")
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
            ContentUnavailableView(
                "Select a Recording",
                systemImage: "sidebar.left",
                description: Text("Choose a recording from the Library to inspect its metadata.")
            )
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(1)

            Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text(durationText(recording.duration))
                Text("•")
                Text(sourceText(recording.sources))
                Text("•")
                Text(stateText(recording.processingState))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
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
        Form {
            Section("Recording") {
                LabeledContent("Title", value: recording.title)
                LabeledContent("Created") {
                    Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                LabeledContent("Duration", value: durationText(recording.duration))
                LabeledContent("Source", value: sourceText(recording.sources))
                LabeledContent("State", value: stateText(recording.processingState))
                LabeledContent("ID", value: recording.id.uuidString)
            }

            if let asset = recording.audioAssets.first {
                Section("Audio") {
                    LabeledContent("Original file", value: asset.originalFileName)
                    LabeledContent("Codec", value: asset.metadata.codec)
                    LabeledContent("Sample rate", value: sampleRateText(asset.metadata.sampleRate))
                    LabeledContent("Channels", value: String(asset.metadata.channelCount))
                }

                Section("Playback") {
                    if let errorMessage = playback.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
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
                        .disabled(!playback.isLoaded)

                        Slider(
                            value: Binding(
                                get: { playback.position },
                                set: { playback.seek(to: $0) }
                            ),
                            in: 0...max(playback.duration, 0.01)
                        )
                        .disabled(!playback.isLoaded)

                        Text("\(durationText(playback.position)) / \(durationText(playback.duration))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Audio") {
                    ContentUnavailableView(
                        "No Managed Audio",
                        systemImage: "waveform.slash",
                        description: Text("This recording predates audio import or has no managed audio resource.")
                    )
                }
            }

            Section("Transcript") {
                transcriptSection
            }
        }
        .formStyle(.grouped)
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

    @ViewBuilder
    private var transcriptSection: some View {
        if model.isTranscribing {
            let progress = model.transcriptionProgress
            VStack(alignment: .leading, spacing: 8) {
                Text(transcriptionStageText(progress?.stage))
                    .font(.headline)
                ProgressView(value: progress?.fractionCompleted ?? 0)
                Text("Audio stays on this Mac while WhisperKit processes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) {
                    model.cancelTranscription()
                }
            }
        } else if let transcript = model.transcript,
                  transcript.recordingID == recording.id {
            transcriptErrors

            if model.isDiarizing, model.diarizationRecordingID == recording.id {
                diarizationProgressView
            } else {
                transcriptToolbar(transcript)
                transcriptConversation(transcript)
                transcriptDetails(transcript)
            }
        } else {
            if let error = model.transcriptErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            Text("Create an on-device transcript with WhisperKit. The model downloads separately the first time you use transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(recording.processingState == .failed ? "Retry Transcription" : "Transcribe") {
                model.beginTranscription()
            }
            .disabled(recording.audioAssets.isEmpty || model.isDiarizing)
        }
    }

    @ViewBuilder
    private var transcriptErrors: some View {
        if let error = model.transcriptErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        if let error = model.diarizationErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        if let error = model.transcriptEditErrorMessage {
            HStack(alignment: .firstTextBaseline) {
                Label(error, systemImage: "exclamationmark.triangle")
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
        return VStack(alignment: .leading, spacing: 8) {
            Text(diarizationStageText(progress?.stage))
                .font(.headline)
            ProgressView(value: progress?.fractionCompleted ?? 0)
            Text("Speaker identification runs locally with SpeakerKit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel Speaker Identification", role: .cancel) {
                model.cancelDiarization()
            }
        }
    }

    private func transcriptToolbar(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(transcript.languageCode ?? "Auto", systemImage: "captions.bubble")
                    .foregroundStyle(.secondary)

                if transcript.diarizationMetadata != nil {
                    Label(
                        "\(transcript.speakers.count) speaker\(transcript.speakers.count == 1 ? "" : "s")",
                        systemImage: "person.2"
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    copyTranscript(transcript)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .disabled(transcript.text.isEmpty)
            }
            .font(.caption)

            HStack(spacing: 8) {
                TextField("Search transcript", text: $transcriptSearch)
                    .textFieldStyle(.roundedBorder)

                if !transcriptSearch.isEmpty {
                    Button {
                        transcriptSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear transcript search")
                }
            }

            HStack {
                Button(transcript.diarizationMetadata == nil ? "Identify Speakers" : "Identify Speakers Again") {
                    if transcript.diarizationMetadata != nil, transcript.hasNamedSpeakers {
                        pendingReplacementAction = .rediariize
                    } else {
                        model.beginDiarization()
                    }
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing)

                Button("Transcribe Again") {
                    if transcript.hasManualChanges {
                        pendingReplacementAction = .retranscribe
                    } else {
                        model.beginTranscription()
                    }
                }
                .disabled(recording.audioAssets.isEmpty || model.isDiarizing)
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
                description: Text("WhisperKit produced no transcript segments for this recording.")
            )
        } else if segments.isEmpty {
            ContentUnavailableView.search(text: transcriptSearch)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(segments) { segment in
                    transcriptTurn(segment, in: transcript)
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
                    Text("Unassigned speaker")
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
                .help("Jump audio to this moment")

                Button {
                    editor = .segment(segment)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isTranscribing || model.isDiarizing)
                .help("Edit transcript text")
            }

            Text(segment.displayText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if segment.editedText != nil {
                Label("Edited transcript text", systemImage: "pencil.line")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func transcriptDetails(_ transcript: Transcript) -> some View {
        DisclosureGroup("Transcript details") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Language", value: transcript.languageCode ?? "Auto-detected")
                LabeledContent("Model", value: transcript.metadata.modelID)
                LabeledContent("Engine", value: "\(transcript.metadata.engine) \(transcript.metadata.engineVersion)")

                if let diarization = transcript.diarizationMetadata {
                    LabeledContent("Speakers", value: String(transcript.speakers.count))
                    LabeledContent(
                        "Speaker engine",
                        value: "\(diarization.engine) \(diarization.engineVersion)"
                    )
                    LabeledContent("Speaker model", value: diarization.modelID)
                }
            }
            .padding(.top, 6)
        }
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
        let fallback = "Speaker \(index + 1)"
        return .speaker(speaker, fallbackName: fallback)
    }

    private func speakerLabel(for segment: TranscriptSegment, in transcript: Transcript) -> String {
        guard let speakerID = segment.speakerID,
              let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else {
            return transcript.speakers.isEmpty ? "Transcript" : "Unassigned speaker"
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
        case .retranscribe:
            "Replace Manual Transcript Changes?"
        case .rediariize:
            "Replace Speaker Names?"
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
        case .retranscribe:
            "Transcribe Again"
        case .rediariize:
            "Identify Speakers Again"
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
            prompt: "Correct the readable transcript without replacing WhisperKit's original timing evidence.",
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
            Text(state.title)
                .font(.title2.weight(.semibold))

            Text(state.prompt)
                .foregroundStyle(.secondary)

            if state.isMultiline {
                TextEditor(text: $value)
                    .font(.body)
                    .frame(minHeight: 150)
                    .padding(6)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                TextField("Speaker name", text: $value)
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
        .padding(20)
        .frame(minWidth: 480, minHeight: state.isMultiline ? 300 : 180)
    }
}

private func transcriptionStageText(_ stage: TranscriptionStage?) -> String {
    switch stage {
    case .preparingModel: "Preparing Whisper Model…"
    case .loadingModel: "Loading Whisper Model…"
    case .transcribing: "Transcribing…"
    case .saving: "Saving Transcript…"
    case nil: "Preparing Transcription…"
    }
}

private func diarizationStageText(_ stage: DiarizationStage?) -> String {
    switch stage {
    case .preparingModel: "Preparing Speaker Model…"
    case .loadingModel: "Loading Speaker Model…"
    case .diarizing: "Identifying Speakers…"
    case .saving: "Saving Speaker Labels…"
    case nil: "Preparing Speaker Identification…"
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
            case .systemAudio: "System audio"
            case .importedFile: "Imported file"
            }
        }
        .joined(separator: " + ")
}

private func stateText(_ state: ProcessingState) -> String {
    switch state {
    case .pending: "Pending"
    case .processing: "Processing"
    case .completed: "Completed"
    case .failed: "Failed"
    }
}
