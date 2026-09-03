import AppKit
import SwiftUI

struct TranscriptContentView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController

    @Binding var searchText: String
    @Binding var editor: TranscriptEditorState?
    @Binding var isSpeakerNamingPresented: Bool

    var onSelectMinutes: (() -> Void)? = nil
    @Namespace private var modelSelectorNamespace

    var body: some View {
        transcriptViewport
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
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(recording.audioAssets.isEmpty || model.isTranscribing || model.isDiarizing)
        case .singleSpeaker:
            Label(String(localized: "1 Speaker"), systemImage: "person")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .participants(let count):
            Button {
                isSpeakerNamingPresented = true
            } label: {
                Label(String.localizedStringWithFormat(String(localized: "%lld Participants"), count), systemImage: "person.2")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isTranscribing || model.isDiarizing)
        }
    }

    private var transcriptViewport: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BardoSpacing.group) {
                transcriptErrors

                if model.isTranscribing {
                    transcriptionProgressView
                } else if let transcript = model.transcript,
                          transcript.recordingID == recording.id {
                    if model.isDiarizing, model.diarizationRecordingID == recording.id {
                        diarizationProgressView
                    } else {
                        transcriptConversation(transcript)

                        if !transcript.segments.isEmpty {
                            minutesNavigationCard
                                .padding(.top, BardoSpacing.section)
                        }
                    }
                } else {
                    emptyTranscriptView
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, BardoSpacing.detailHorizontal)
            .padding(.vertical, BardoSpacing.section)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollClipDisabled(false)
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
                .buttonStyle(.link)
            }
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
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(String(localized: "No Transcript Yet"))
                    .font(BardoTypography.sectionTitle)
                Text(String(localized: "Create a private, on-device transcript. Choose the model that fits your speed and precision needs."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            modelPresetSelector
                .padding(.vertical, 4)

            Button {
                model.beginTranscription()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                    Text(recording.processingState == .failed ? String(localized: "Retry Transcription") : String(localized: "Transcribe"))
                        .font(.body.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(recording.audioAssets.isEmpty || model.isDiarizing)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(28)
        .background(.fill.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var modelPresetSelector: some View {
        HStack(spacing: 3) {
            ForEach(TranscriptionOption.catalog) { option in
                let isSelected = model.selectedTranscriptionPreset == option.preset
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        model.selectedTranscriptionPreset = option.preset
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: iconForPreset(option.preset))
                            .font(.system(size: 11, weight: .medium))

                        Text(option.label)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "selectedPresetCapsule", in: modelSelectorNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.fill.quaternary.opacity(0.7), in: Capsule())
    }

    private func iconForPreset(_ preset: TranscriptionPreset) -> String {
        switch preset {
        case .instant: "bolt.fill"
        case .balanced: "waveform"
        case .maximumAccuracy: "sparkles"
        }
    }

    @ViewBuilder
    private func transcriptConversation(_ transcript: Transcript) -> some View {
        let segments = filteredSegments(in: transcript)

        if transcript.segments.isEmpty {
            ContentUnavailableView(
                String(localized: "Empty Transcript"),
                systemImage: "text.bubble",
                description: Text(String(localized: "WhisperKit produced no readable transcript segments for this recording."))
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
                                .padding(.vertical, 14)
                        }
                        speakerHeader(for: segment, in: transcript)
                            .padding(.bottom, 5)
                    }

                    TranscriptSegmentRow(
                        segment: segment,
                        playback: playback,
                        canEdit: !model.isTranscribing && !model.isDiarizing,
                        onEdit: { editor = .segment(segment) }
                    )
                    .padding(.bottom, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func speakerHeader(for segment: TranscriptSegment, in transcript: Transcript) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .font(.subheadline)
                .foregroundStyle(.tint)

            if let speakerID = segment.speakerID,
               transcript.speakers.contains(where: { $0.id == speakerID }) {
                Button {
                    editor = speakerEditorState(speakerID: speakerID, transcript: transcript)
                } label: {
                    Text(speakerLabel(for: segment, in: transcript))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Rename this speaker"))
            } else {
                Text(speakerLabel(for: segment, in: transcript))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(transcript.speakers.isEmpty ? .primary : .secondary)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
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
        return .speaker(speaker, fallbackName: String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1))
    }

    private func speakerLabel(for segment: TranscriptSegment, in transcript: Transcript) -> String {
        guard let speakerID = segment.speakerID,
              let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else {
            return transcript.speakers.isEmpty ? String(localized: "Transcript") : String(localized: "Unassigned Speaker")
        }

        let speaker = transcript.speakers[index]
        if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
    }

    private var minutesNavigationCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "list.bullet.clipboard")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Meeting Minutes"))
                    .font(.headline)
                Text(String(localized: "Synthesize key points, decisions, and action items with Qwen in its dedicated tab."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onSelectMinutes?()
            } label: {
                Label(
                    model.meetingMinutes?.recordingID == recording.id
                        ? String(localized: "View Minutes")
                        : String(localized: "Open Minutes Tab"),
                    systemImage: "arrow.right"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(.fill.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    @ObservedObject var playback: AudioPlaybackController
    let canEdit: Bool
    let onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                playback.seek(to: segment.startTime)
            } label: {
                Text(LibraryFormatting.duration(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .frame(width: 42, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help(String.localizedStringWithFormat(String(localized: "Play from %@"), LibraryFormatting.duration(segment.startTime)))

            Text(segment.displayText)
                .font(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if segment.editedText != nil {
                Image(systemName: "pencil.line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "Edited"))
                    .accessibilityLabel(String(localized: "Edited"))
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovering || segment.editedText != nil ? 1 : 0)
            .disabled(!canEdit)
            .help(String(localized: "Edit transcript text"))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button(String(localized: "Play From Here")) {
                playback.seek(to: segment.startTime)
                _ = playback.play()
            }
            .disabled(!playback.isLoaded)

            Button(String(localized: "Edit Transcript…"), action: onEdit)
                .disabled(!canEdit)

            Divider()

            Button(String(localized: "Copy Segment")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.displayText, forType: .string)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InlineIssueView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
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
