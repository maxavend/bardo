import AppKit
import Foundation
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
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader

            transcriptErrors

            if let transcript = model.transcript,
               transcript.recordingID == recording.id {
                backgroundProcessingStatus
                transcriptConversation(transcript)
            } else if isCurrentTranscription {
                transcriptionProgressView
            } else {
                emptyTranscriptView
            }
        }
    }

    private var isCurrentTranscription: Bool {
        model.isTranscribing && model.transcriptionRecordingID == recording.id
    }

    private var isCurrentDiarization: Bool {
        model.isDiarizing && model.diarizationRecordingID == recording.id
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Transcript")
                .font(.headline)

            if let transcript = model.transcript,
               transcript.recordingID == recording.id {
                Text(LibraryFormatting.language(transcript.languageCode))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if transcript.diarizationMetadata != nil {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("\(transcript.speakers.count) speaker\(transcript.speakers.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
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

    @ViewBuilder
    private var backgroundProcessingStatus: some View {
        if isCurrentDiarization {
            let progress = model.diarizationProgress
            BackgroundProcessingView(
                systemImage: "person.2.wave.2",
                title: diarizationStageText(progress?.stage),
                detail: "You can keep reading, searching, copying, and playing this transcript while Bardo analyzes the voices.",
                fractionCompleted: progress?.fractionCompleted ?? 0,
                cancelTitle: "Cancel Speaker Identification",
                cancelAction: { model.cancelDiarization() }
            )
        } else if isCurrentTranscription {
            let progress = model.transcriptionProgress
            BackgroundProcessingView(
                systemImage: "waveform",
                title: transcriptionStageText(progress?.stage),
                detail: "The current transcript stays available until the new transcription is ready.",
                fractionCompleted: progress?.fractionCompleted ?? 0,
                cancelTitle: "Cancel",
                cancelAction: { model.cancelTranscription() }
            )
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
        .frame(maxWidth: .infinity, minHeight: 230)
    }

    @ViewBuilder
    private func transcriptConversation(_ transcript: Transcript) -> some View {
        let blocks = TranscriptReadingBlockBuilder.blocks(from: transcript.segments)

        if transcript.segments.isEmpty || blocks.isEmpty {
            ContentUnavailableView(
                "No Speech Found",
                systemImage: "text.bubble",
                description: Text("Bardo processed the recording but didn’t find readable speech.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVStack(alignment: .leading, spacing: BardoDesignMetrics.transcriptBlockSpacing) {
                ForEach(blocks) { block in
                    TranscriptReadingBlockRow(
                        block: block,
                        speakerName: transcript.speakers.isEmpty ? nil : speakerLabel(for: block, in: transcript),
                        canRenameSpeaker: canRenameSpeaker(for: block, in: transcript),
                        playback: playback,
                        isActive: activeBlockID == block.id,
                        canEdit: !model.isTranscribing && !model.isDiarizing,
                        searchText: searchText,
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
                    blocks: blocks,
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
    let searchText: String
    let onRenameSpeaker: () -> Void
    let onEditSegment: (TranscriptSegment) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 5) {
                Text(LibraryFormatting.duration(block.startTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Button(action: playFromBlock) {
                    Image(systemName: isActive && playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovering || isActive ? 1 : 0.18)
                .disabled(!playback.isLoaded)
                .help("Play From Here")
                .accessibilityLabel("Play From Here")
            }
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 7) {
                if let speakerName {
                    if canRenameSpeaker {
                        Button(speakerName, action: onRenameSpeaker)
                            .buttonStyle(.plain)
                            .font(.subheadline.weight(.semibold))
                            .help("Rename this speaker")
                            .padding(.trailing, 32)
                    } else {
                        Text(speakerName)
                            .font(.subheadline.weight(.semibold))
                            .padding(.trailing, 32)
                    }
                }

                if isActive && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TranscriptKaraokeText(
                        block: block,
                        timeline: playback.timeline
                    )
                } else {
                    TranscriptSearchHighlightedText(text: block.text, query: searchText)
                }

                if block.hasManualEdits {
                    Label("Edited", systemImage: "pencil.line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .topTrailing) {
                blockEditControl
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2)
                .padding(.vertical, 8)
                .opacity(isActive ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityValue(isActive ? "Playing" : "")
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
            .opacity(isHovering || block.hasManualEdits ? 1 : 0.12)
            .disabled(!canEdit)
            .help("Edit transcript text")
            .accessibilityLabel("Edit transcript text")
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
            .opacity(isHovering || block.hasManualEdits ? 1 : 0.12)
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
        if isActive && playback.isPlaying {
            playback.pause()
            return
        }
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

private struct TranscriptSearchHighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        renderedText
            .font(.body)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedText: Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Text(text) }

        var remaining = text
        var result = Text("")
        while let range = remaining.range(
            of: trimmed,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) {
            result = result
                + Text(String(remaining[..<range.lowerBound]))
                + Text(String(remaining[range])).foregroundColor(.accentColor).bold()
            remaining = String(remaining[range.upperBound...])
        }
        return result + Text(remaining)
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

private struct BackgroundProcessingView: View {
    let systemImage: String
    let title: String
    let detail: String
    let fractionCompleted: Double
    let cancelTitle: String
    let cancelAction: () -> Void

    private var clampedProgress: Double {
        min(1, max(0, fractionCompleted.isFinite ? fractionCompleted : 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text("\(Int((clampedProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                Button(role: .cancel, action: cancelAction) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(cancelTitle)
                .accessibilityLabel(cancelTitle)
            }

            ProgressView(value: clampedProgress)
                .controlSize(.small)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: BardoDesignMetrics.compactCornerRadius, style: .continuous))
    }
}

private struct ProcessingView: View {
    let title: String
    let detail: String
    let fractionCompleted: Double
    let cancelTitle: String
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
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
                Spacer(minLength: 12)
                Button(cancelTitle, role: .cancel, action: cancelAction)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: BardoDesignMetrics.compactCornerRadius, style: .continuous))
    }
}

private struct InlineIssueView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func transcriptionStageText(_ stage: TranscriptionStage?) -> String {
    switch stage {
    case .preparingModel: "Preparing the transcription…"
    case .loadingModel: "Getting transcription ready…"
    case .transcribing: "Creating a new transcription…"
    case .saving: "Replacing the transcript…"
    case nil: "Preparing the transcription…"
    }
}

private func diarizationStageText(_ stage: DiarizationStage?) -> String {
    switch stage {
    case .preparingModel: "Preparing speaker identification…"
    case .loadingModel: "Loading speaker models…"
    case .diarizing: "Identifying speakers…"
    case .saving: "Applying speaker labels…"
    case nil: "Preparing speaker identification…"
    }
}
