import AppKit
import SwiftUI

struct TranscriptContentView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @Binding var searchText: String
    @Binding var editor: TranscriptEditorState?

    let onPlaybackBlockChange: (TranscriptReadingBlock.ID?) -> Void

    @State private var activeBlockID: TranscriptReadingBlock.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionHeader

            transcriptErrors

            if model.isTranscribing, model.transcriptionRecordingID == recording.id {
                transcriptionProgressView
            } else if let transcript = model.transcript,
                      transcript.recordingID == recording.id {
                if model.isDiarizing, model.diarizationRecordingID == recording.id {
                    diarizationProgressView
                } else {
                    transcriptConversation(transcript)
                }
            } else {
                emptyTranscriptView
            }
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Transcript")
                .font(.title2.weight(.semibold))

            if let transcript = model.transcript,
               transcript.recordingID == recording.id {
                Text(LibraryFormatting.language(transcript.languageCode))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if transcript.diarizationMetadata != nil {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(transcript.speakers.count) speaker\(transcript.speakers.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var transcriptErrors: some View {
        if let error = model.transcriptErrorMessage {
            InlineIssueView(message: error)
        }
        if let error = model.diarizationErrorMessage {
            InlineIssueView(message: error)
        }
        if let error = model.transcriptEditErrorMessage {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                InlineIssueView(message: error)
                Spacer()
                Button("Dismiss") {
                    model.clearTranscriptEditError()
                }
                .buttonStyle(.link)
            }
        }
    }

    private var transcriptionProgressView: some View {
        let progress = model.transcriptionProgress
        return ProcessingView(
            title: transcriptionStageText(progress?.stage),
            detail: "Your audio stays on this Mac while Bardo prepares and transcribes it.",
            fractionCompleted: progress?.fractionCompleted ?? 0,
            cancelTitle: "Cancel",
            cancelAction: { model.cancelTranscription() }
        )
    }

    private var diarizationProgressView: some View {
        let progress = model.diarizationProgress
        return ProcessingView(
            title: diarizationStageText(progress?.stage),
            detail: "Bardo is telling the voices apart locally on this Mac.",
            fractionCompleted: progress?.fractionCompleted ?? 0,
            cancelTitle: "Cancel Speaker Identification",
            cancelAction: { model.cancelDiarization() }
        )
    }

    private var emptyTranscriptView: some View {
        ContentUnavailableView {
            Label("No Transcript Yet", systemImage: "captions.bubble")
        } description: {
            Text("Create a private transcript right on this Mac. Once setup is finished, no cloud transcription is needed.")
        } actions: {
            Button(recording.processingState == .failed || recording.processingState == .partial ? "Retry Transcription" : "Transcribe") {
                model.beginTranscription()
            }
            .disabled(recording.audioAssets.isEmpty || model.isDiarizing || model.isTranscribing)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
    }

    @ViewBuilder
    private func transcriptConversation(_ transcript: Transcript) -> some View {
        let allBlocks = TranscriptReadingBlockBuilder.blocks(from: transcript.segments)
        let blocks = filteredBlocks(allBlocks, in: transcript)

        if transcript.segments.isEmpty || allBlocks.isEmpty {
            ContentUnavailableView(
                "No Speech Found",
                systemImage: "text.bubble",
                description: Text("Bardo processed the recording but didn’t find readable speech.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if blocks.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    TranscriptReadingBlockRow(
                        block: block,
                        speakerName: transcript.speakers.isEmpty ? nil : speakerLabel(for: block, in: transcript),
                        canRenameSpeaker: canRenameSpeaker(for: block, in: transcript),
                        playback: playback,
                        isActive: activeBlockID == block.id,
                        canEdit: !model.isTranscribing && !model.isDiarizing,
                        onRenameSpeaker: {
                            guard let speakerID = block.speakerID else { return }
                            editor = speakerEditorState(speakerID: speakerID, transcript: transcript)
                        },
                        onEditSegment: { segment in
                            editor = .segment(segment)
                        }
                    )
                    .id(block.id)
                }
            }
            .background(alignment: .topLeading) {
                TranscriptPlaybackTracker(
                    timeline: playback.timeline,
                    blocks: allBlocks,
                    isPlaying: playback.isPlaying
                ) { blockID, shouldFollow in
                    if activeBlockID != blockID {
                        activeBlockID = blockID
                    }

                    if shouldFollow, let blockID {
                        onPlaybackBlockChange(blockID)
                    }
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
    }

    private func filteredBlocks(
        _ blocks: [TranscriptReadingBlock],
        in transcript: Transcript
    ) -> [TranscriptReadingBlock] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return blocks }

        return blocks.filter { block in
            block.text.localizedCaseInsensitiveContains(query)
                || speakerLabel(for: block, in: transcript).localizedCaseInsensitiveContains(query)
        }
    }

    private func canRenameSpeaker(for block: TranscriptReadingBlock, in transcript: Transcript) -> Bool {
        guard let speakerID = block.speakerID else { return false }
        return transcript.speakers.contains { $0.id == speakerID }
    }

    private func speakerEditorState(speakerID: Speaker.ID, transcript: Transcript) -> TranscriptEditorState? {
        guard let speaker = transcript.speakers.first(where: { $0.id == speakerID }) else { return nil }
        let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) ?? 0
        return .speaker(speaker, fallbackName: "Speaker \(index + 1)")
    }

    private func speakerLabel(for block: TranscriptReadingBlock, in transcript: Transcript) -> String {
        guard let speakerID = block.speakerID,
              let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else {
            return transcript.speakers.isEmpty ? "Transcript" : "Unassigned Speaker"
        }

        let speaker = transcript.speakers[index]
        if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Speaker \(index + 1)"
    }
}

private struct TranscriptReadingBlockRow: View {
    let block: TranscriptReadingBlock
    let speakerName: String?
    let canRenameSpeaker: Bool
    let playback: AudioPlaybackController
    let isActive: Bool
    let canEdit: Bool
    let onRenameSpeaker: () -> Void
    let onEditSegment: (TranscriptSegment) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: playFromBlock) {
                VStack(spacing: 5) {
                    Image(systemName: isActive && playback.isPlaying ? "waveform" : "play.fill")
                        .font(.caption2.weight(.semibold))
                        .frame(height: 12)
                        .symbolEffect(.variableColor.iterative, isActive: isActive && playback.isPlaying)

                    Text(LibraryFormatting.duration(block.startTime))
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 46, alignment: .center)
                .padding(.top, speakerName == nil ? 2 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help("Play From Here")

            VStack(alignment: .leading, spacing: 7) {
                if let speakerName {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if canRenameSpeaker {
                            Button(speakerName, action: onRenameSpeaker)
                                .buttonStyle(.plain)
                                .font(.subheadline.weight(.semibold))
                                .help("Rename this speaker")
                        } else {
                            Text(speakerName)
                                .font(.subheadline.weight(.semibold))
                        }

                        Spacer(minLength: 12)
                        blockEditControl
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Spacer(minLength: 0)
                        blockEditControl
                    }
                    .frame(height: 0)
                }

                Text(block.text)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if block.hasManualEdits {
                    Label("Edited", systemImage: "pencil.line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.075) : Color.clear)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3)
                .padding(.vertical, 12)
                .opacity(isActive ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 1), value: isActive)
        .contextMenu {
            Button("Play From Here", action: playFromBlock)
                .disabled(!playback.isLoaded)

            if canEdit {
                editActions
            }

            Divider()

            Button("Copy Block") {
                NSPasteboard.general.clearContents()
                _ = NSPasteboard.general.setString(block.text, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var blockEditControl: some View {
        if block.segments.count == 1, let segment = block.segments.first {
            Button {
                onEditSegment(segment)
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || block.hasManualEdits ? 1 : 0.16)
            .disabled(!canEdit)
            .help("Edit transcript text")
        } else {
            Menu {
                editActions
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .opacity(isHovering || block.hasManualEdits ? 1 : 0.16)
            .disabled(!canEdit)
            .help("Edit Transcript…")
        }
    }

    @ViewBuilder
    private var editActions: some View {
        if block.segments.count == 1, let segment = block.segments.first {
            Button("Edit Transcript…") {
                onEditSegment(segment)
            }
        } else {
            Section("Edit Segment") {
                ForEach(block.segments) { segment in
                    Button(segmentMenuTitle(segment)) {
                        onEditSegment(segment)
                    }
                }
            }
        }
    }

    private func playFromBlock() {
        playback.seek(to: block.startTime)
        if !playback.isPlaying {
            _ = playback.play()
        }
    }

    private func segmentMenuTitle(_ segment: TranscriptSegment) -> String {
        let text = segment.displayText
        let limit = 44
        let preview = text.count > limit ? String(text.prefix(limit)) + "…" : text
        return "\(LibraryFormatting.duration(segment.startTime)) · \(preview)"
    }
}

private struct TranscriptPlaybackTracker: View {
    @ObservedObject var timeline: AudioPlaybackTimeline
    let blocks: [TranscriptReadingBlock]
    let isPlaying: Bool
    let onActiveBlockChange: (TranscriptReadingBlock.ID?, Bool) -> Void

    @State private var lastReportedID: TranscriptReadingBlock.ID?

    var body: some View {
        Color.clear
            .onAppear {
                report(position: timeline.position, shouldFollow: false, force: true)
            }
            .onChange(of: timeline.position) { _, position in
                report(position: position, shouldFollow: isPlaying)
            }
            .onChange(of: isPlaying) { _, nowPlaying in
                guard nowPlaying else { return }
                report(position: timeline.position, shouldFollow: true, force: true)
            }
            .onChange(of: blocks.map(\.id)) { _, _ in
                report(position: timeline.position, shouldFollow: false, force: true)
            }
    }

    private func report(
        position: TimeInterval,
        shouldFollow: Bool,
        force: Bool = false
    ) {
        let blockID = TranscriptPlaybackMapping.activeBlockID(at: position, in: blocks)
        guard force || blockID != lastReportedID else { return }
        lastReportedID = blockID
        onActiveBlockChange(blockID, shouldFollow)
    }
}

private struct ProcessingView: View {
    let title: String
    let detail: String
    let fractionCompleted: Double
    let cancelTitle: String
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.headline)
            }

            ProgressView(value: fractionCompleted)

            HStack(alignment: .firstTextBaseline) {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(cancelTitle, role: .cancel, action: cancelAction)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct InlineIssueView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

private func transcriptionStageText(_ stage: TranscriptionStage?) -> String {
    switch stage {
    case .preparingModel: "Preparing the transcription…"
    case .loadingModel: "Getting transcription ready…"
    case .transcribing: "Transcribing your recording…"
    case .saving: "Saving the transcript…"
    case nil: "Preparing the transcription…"
    }
}

private func diarizationStageText(_ stage: DiarizationStage?) -> String {
    switch stage {
    case .preparingModel: "Preparing speaker identification…"
    case .loadingModel: "Getting speaker identification ready…"
    case .diarizing: "Figuring out who said what…"
    case .saving: "Saving speaker labels…"
    case nil: "Preparing speaker identification…"
    }
}
