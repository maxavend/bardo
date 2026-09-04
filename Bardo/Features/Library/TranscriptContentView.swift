import AppKit
import SwiftUI

struct TranscriptContentView: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @Binding var searchText: String
    @Binding var editor: TranscriptEditorState?
    @Binding var isSpeakerNamingPresented: Bool

    var onSelectMinutes: (() -> Void)? = nil

    var body: some View {
        transcriptViewport
            .enableInjection()
    }

    private var transcriptViewport: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BardoSpacing.section) {
                transcriptErrors

                if model.isTranscribing {
                    transcriptionProgressView
                } else if let transcript = model.transcript,
                          transcript.recordingID == recording.id {
                    if model.isDiarizing, model.diarizationRecordingID == recording.id {
                        diarizationProgressView
                    } else {
                        transcriptHeader(for: transcript)
                        transcriptConversation(transcript)

                        if !transcript.segments.isEmpty {
                            minutesNavigationGroup
                                .padding(.top, 8)
                        }
                    }
                } else {
                    emptyTranscriptView
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, BardoSpacing.detailHorizontal)
            .padding(.vertical, BardoSpacing.section)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button(String(localized: "Dismiss")) {
                    model.clearTranscriptEditError()
                }
            }
        }
    }

    private func transcriptHeader(for transcript: Transcript) -> some View {
        HStack(spacing: 10) {
            speakerControl(for: transcript)

            if transcript.segments.contains(where: { $0.editedText != nil }) {
                Label(String(localized: "Edited"), systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "This transcript contains manual corrections. Original recognition text is preserved."))
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func speakerControl(for transcript: Transcript) -> some View {
        switch SpeakerNamingPolicy.presentation(for: transcript) {
        case .identifySpeakers:
            Button {
                model.beginDiarization()
            } label: {
                Label(String(localized: "Identify Speakers"), systemImage: "person.2.wave.2")
            }
            .disabled(recording.audioAssets.isEmpty || model.isTranscribing || model.isDiarizing)

        case .singleSpeaker:
            Label(String(localized: "1 Speaker"), systemImage: "person")
                .foregroundStyle(.secondary)

        case .participants(let count):
            Button {
                isSpeakerNamingPresented = true
            } label: {
                Label(
                    String.localizedStringWithFormat(String(localized: "%lld Participants"), count),
                    systemImage: "person.2"
                )
            }
            .disabled(model.isTranscribing || model.isDiarizing)
        }
    }

    private var transcriptionProgressView: some View {
        let progress = model.transcriptionProgress
        return ProcessingView(
            title: transcriptionStageText(progress?.stage),
            detail: String(localized: "Audio stays on this Mac while Bardo processes it."),
            fractionCompleted: progress?.fractionCompleted ?? 0,
            cancelTitle: String(localized: "Cancel"),
            cancelAction: { model.cancelTranscription() }
        )
    }

    private var diarizationProgressView: some View {
        let progress = model.diarizationProgress
        return ProcessingView(
            title: diarizationStageText(progress?.stage),
            detail: String(localized: "Speaker identification runs locally with SpeakerKit."),
            fractionCompleted: progress?.fractionCompleted ?? 0,
            cancelTitle: String(localized: "Cancel Speaker Identification"),
            cancelAction: { model.cancelDiarization() }
        )
    }

    private var emptyTranscriptView: some View {
        ContentUnavailableView {
            Label(String(localized: "Aún no hay transcripción"), systemImage: "waveform.and.mic")
        } description: {
            Text(String(localized: "Crea una transcripción privada y local con Whisper Large v3 Turbo."))
        } actions: {
            Button {
                model.beginTranscription()
            } label: {
                Label(
                    recording.processingState == .failed
                        ? String(localized: "Retry Transcription")
                        : String(localized: "Transcribir"),
                    systemImage: "waveform.badge.magnifyingglass"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(recording.audioAssets.isEmpty || model.isDiarizing)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func buildParagraphs(from segments: [TranscriptSegment]) -> [TranscriptParagraph] {
        guard !segments.isEmpty else { return [] }

        var paragraphs: [TranscriptParagraph] = []
        var currentBatch: [TranscriptSegment] = []
        var currentSpeakerID: Speaker.ID? = segments.first?.speakerID
        var batchStartTime: TimeInterval = segments.first?.startTime ?? 0

        for segment in segments {
            let speakerChanged = segment.speakerID != currentSpeakerID
            let pauseDuration = currentBatch.last.map { segment.startTime - $0.endTime } ?? 0
            let significantPause = pauseDuration > 1.5

            if !currentBatch.isEmpty && (speakerChanged || significantPause) {
                paragraphs.append(
                    TranscriptParagraph(
                        id: currentBatch.first?.id ?? UUID(),
                        speakerID: currentSpeakerID,
                        startTime: batchStartTime,
                        segments: currentBatch
                    )
                )
                currentBatch = [segment]
                currentSpeakerID = segment.speakerID
                batchStartTime = segment.startTime
            } else {
                if currentBatch.isEmpty {
                    batchStartTime = segment.startTime
                    currentSpeakerID = segment.speakerID
                }
                currentBatch.append(segment)
            }
        }

        if !currentBatch.isEmpty {
            paragraphs.append(
                TranscriptParagraph(
                    id: currentBatch.first?.id ?? UUID(),
                    speakerID: currentSpeakerID,
                    startTime: batchStartTime,
                    segments: currentBatch
                )
            )
        }

        return paragraphs
    }

    @ViewBuilder
    private func transcriptConversation(_ transcript: Transcript) -> some View {
        let segments = filteredSegments(in: transcript)
        let paragraphs = buildParagraphs(from: segments)

        if transcript.segments.isEmpty {
            ContentUnavailableView(
                String(localized: "Empty Transcript"),
                systemImage: "text.bubble",
                description: Text(String(localized: "WhisperKit produced no readable transcript segments for this recording."))
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if paragraphs.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(Array(paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                    let currentSpeaker = speakerLabel(for: paragraph.speakerID, in: transcript)
                    let previousSpeaker = index > 0
                        ? speakerLabel(for: paragraphs[index - 1].speakerID, in: transcript)
                        : nil
                    let startsSpeakerTurn = currentSpeaker != previousSpeaker

                    VStack(alignment: .leading, spacing: 7) {
                        if !transcript.speakers.isEmpty && (startsSpeakerTurn || index == 0) {
                            speakerHeader(speakerID: paragraph.speakerID, in: transcript)
                        }

                        TranscriptParagraphRow(
                            paragraph: paragraph,
                            playback: playback,
                            canEdit: !model.isTranscribing && !model.isDiarizing,
                            onEditSegment: { segment in editor = .segment(segment) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func speakerHeader(speakerID: Speaker.ID?, in transcript: Transcript) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            if let speakerID,
               transcript.speakers.contains(where: { $0.id == speakerID }) {
                Button {
                    editor = speakerEditorState(speakerID: speakerID, transcript: transcript)
                } label: {
                    Text(speakerLabel(for: speakerID, in: transcript))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Rename this speaker"))
            } else {
                Text(speakerLabel(for: speakerID, in: transcript))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(transcript.speakers.isEmpty ? Color.primary : Color.secondary)
            }
        }
    }

    private func filteredSegments(in transcript: Transcript) -> [TranscriptSegment] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return transcript.segments }

        return transcript.segments.filter { segment in
            segment.displayText.localizedCaseInsensitiveContains(query)
                || speakerLabel(for: segment.speakerID, in: transcript).localizedCaseInsensitiveContains(query)
        }
    }

    private func speakerEditorState(speakerID: Speaker.ID, transcript: Transcript) -> TranscriptEditorState? {
        guard let speaker = transcript.speakers.first(where: { $0.id == speakerID }) else { return nil }
        let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) ?? 0
        return .speaker(
            speaker,
            fallbackName: String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
        )
    }

    private func speakerLabel(for speakerID: Speaker.ID?, in transcript: Transcript) -> String {
        guard let speakerID,
              let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else {
            return transcript.speakers.isEmpty
                ? String(localized: "Transcript")
                : String(localized: "Unassigned Speaker")
        }

        let speaker = transcript.speakers[index]
        if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
    }

    private var minutesNavigationGroup: some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(localized: "Synthesize key points, decisions, and action items from this transcript."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 16)

                Button {
                    onSelectMinutes?()
                } label: {
                    Label(
                        model.meetingMinutes?.recordingID == recording.id
                            ? String(localized: "View Minutes")
                            : String(localized: "Open Minutes"),
                        systemImage: "arrow.right"
                    )
                }
            }
        } label: {
            Label(String(localized: "Meeting Minutes"), systemImage: "list.bullet.clipboard")
        }
    }
}

private struct TranscriptParagraph: Identifiable {
    let id: UUID
    let speakerID: Speaker.ID?
    let startTime: TimeInterval
    let segments: [TranscriptSegment]

    var fullText: String {
        segments.map(\.displayText).joined(separator: " ")
    }

    var hasEdits: Bool {
        segments.contains { $0.editedText != nil }
    }
}

private struct TranscriptParagraphRow: View {
    let paragraph: TranscriptParagraph
    @ObservedObject var playback: AudioPlaybackController
    let canEdit: Bool
    let onEditSegment: (TranscriptSegment) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                playback.seek(to: paragraph.startTime)
                _ = playback.play()
            } label: {
                Text(LibraryFormatting.duration(paragraph.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help(
                String.localizedStringWithFormat(
                    String(localized: "Play from %@"),
                    LibraryFormatting.duration(paragraph.startTime)
                )
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(paragraph.fullText)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if paragraph.hasEdits {
                    Label(String(localized: "Edited"), systemImage: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Play From Here")) {
                playback.seek(to: paragraph.startTime)
                _ = playback.play()
            }
            .disabled(!playback.isLoaded)

            if paragraph.segments.count == 1, let segment = paragraph.segments.first {
                Button(String(localized: "Edit Segment…")) {
                    onEditSegment(segment)
                }
                .disabled(!canEdit)
            } else if paragraph.segments.count > 1 {
                Menu(String(localized: "Edit Segment")) {
                    ForEach(paragraph.segments) { segment in
                        Button(segmentMenuTitle(segment)) {
                            onEditSegment(segment)
                        }
                    }
                }
                .disabled(!canEdit)
            }

            Divider()

            Button(String(localized: "Copy Paragraph")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paragraph.fullText, forType: .string)
            }
        }
    }

    private func segmentMenuTitle(_ segment: TranscriptSegment) -> String {
        let compactText = segment.displayText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(42)
        return "\(LibraryFormatting.duration(segment.startTime)) · \(compactText)"
    }
}

private struct ProcessingView: View {
    let title: String
    let detail: String
    let fractionCompleted: Double
    let cancelTitle: String
    let cancelAction: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: fractionCompleted)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Button(cancelTitle, role: .cancel, action: cancelAction)
                }
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct InlineIssueView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func transcriptionStageText(_ stage: TranscriptionStage?) -> String {
    switch stage {
    case .preparingModel: String(localized: "Preparing Speech Model…")
    case .loadingModel: String(localized: "Loading Speech Model…")
    case .transcribing: String(localized: "Transcribing…")
    case .saving: String(localized: "Saving Transcript…")
    case nil: String(localized: "Preparing Transcription…")
    }
}

private func diarizationStageText(_ stage: DiarizationStage?) -> String {
    switch stage {
    case .preparingModel: String(localized: "Preparing Speaker Model…")
    case .loadingModel: String(localized: "Loading Speaker Model…")
    case .diarizing: String(localized: "Identifying Speakers…")
    case .saving: String(localized: "Saving Speaker Labels…")
    case nil: String(localized: "Preparing Speaker Identification…")
    }
}