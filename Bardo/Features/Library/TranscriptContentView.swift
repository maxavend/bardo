import AppKit
import SwiftUI

struct TranscriptContentView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    let playback: AudioPlaybackController

    @Binding var searchText: String
    @Binding var editor: TranscriptEditorState?

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
        let segments = filteredSegments(in: transcript)

        if transcript.segments.isEmpty {
            ContentUnavailableView(
                "No Speech Found",
                systemImage: "text.bubble",
                description: Text("Bardo processed the recording but didn’t find readable speech.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if segments.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let currentSpeaker = speakerLabel(for: segment, in: transcript)
                    let previousSpeaker = index > 0
                        ? speakerLabel(for: segments[index - 1], in: transcript)
                        : nil
                    let startsSpeakerTurn = currentSpeaker != previousSpeaker

                    if !transcript.speakers.isEmpty, startsSpeakerTurn {
                        if index > 0 {
                            Divider()
                                .padding(.vertical, 22)
                        }
                        speakerHeader(for: segment, in: transcript)
                            .padding(.bottom, 8)
                    }

                    TranscriptSegmentRow(
                        segment: segment,
                        playback: playback,
                        canEdit: !model.isTranscribing && !model.isDiarizing,
                        onEdit: { editor = .segment(segment) }
                    )
                    .padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func speakerHeader(for segment: TranscriptSegment, in transcript: Transcript) -> some View {
        if let speakerID = segment.speakerID,
           transcript.speakers.contains(where: { $0.id == speakerID }) {
            Button(speakerLabel(for: segment, in: transcript)) {
                editor = speakerEditorState(speakerID: speakerID, transcript: transcript)
            }
            .buttonStyle(.plain)
            .font(.headline)
            .help("Rename this speaker")
        } else {
            Text(speakerLabel(for: segment, in: transcript))
                .font(.headline)
                .foregroundStyle(transcript.speakers.isEmpty ? .primary : .secondary)
        }
    }

    private func filteredSegments(in transcript: Transcript) -> [TranscriptSegment] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let playback: AudioPlaybackController
    let canEdit: Bool
    let onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Button {
                playback.seek(to: segment.startTime)
            } label: {
                Text(LibraryFormatting.duration(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help("Play from \(LibraryFormatting.duration(segment.startTime))")

            VStack(alignment: .leading, spacing: 5) {
                Text(segment.displayText)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if segment.editedText != nil {
                    Label("Edited", systemImage: "pencil.line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || segment.editedText != nil ? 1 : 0.18)
            .disabled(!canEdit)
            .help("Edit transcript text")
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play From Here") {
                playback.seek(to: segment.startTime)
                _ = playback.play()
            }
            .disabled(!playback.isLoaded)

            Button("Edit Transcript…", action: onEdit)
                .disabled(!canEdit)

            Divider()

            Button("Copy Segment") {
                NSPasteboard.general.clearContents()
                _ = NSPasteboard.general.setString(segment.displayText, forType: .string)
            }
        }
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
