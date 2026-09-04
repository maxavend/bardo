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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLiveTranscription = true

    var bottomContentInset: CGFloat = 0
    var onSelectMinutes: (() -> Void)? = nil

    var body: some View {
        transcriptViewport
            .enableInjection()
    }

    private var transcriptViewport: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: BardoSpacing.section) {
                    transcriptErrors

                    if isTranscribingThisRecording {
                        transcriptionLiveView
                    } else if let transcript = model.transcript,
                              transcript.recordingID == recording.id {
                        if model.isDiarizing, model.diarizationRecordingID == recording.id {
                            diarizationProgressView
                        }

                        transcriptHeader(for: transcript)
                        transcriptConversation(transcript)

                        if !transcript.segments.isEmpty {
                            minutesNavigationGroup
                                .padding(.top, 8)
                        }
                    } else {
                        emptyTranscriptView
                    }

                    Color.clear
                        .frame(height: max(1, bottomContentInset))
                        .id(LiveTranscriptAnchor.tail)
                }
                .frame(maxWidth: BardoLayout.detailContentMaxWidth, alignment: .leading)
                .padding(.horizontal, BardoSpacing.detailHorizontal)
                .padding(.top, 8)
                .padding(.bottom, BardoSpacing.section)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting {
                    followsLiveTranscription = false
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 40
            } action: { _, isAtBottom in
                if isAtBottom && isTranscribingThisRecording {
                    followsLiveTranscription = true
                }
            }
            .onChange(of: liveSegmentCount) { _, _ in
                followLiveTranscript(using: proxy)
            }
            .onChange(of: model.transcriptionRecordingID) { _, recordingID in
                if recordingID == recording.id {
                    followsLiveTranscription = true
                    followLiveTranscript(using: proxy)
                }
            }
            .overlay(alignment: .bottom) {
                if isTranscribingThisRecording && !followsLiveTranscription {
                    HStack {
                        Spacer(minLength: 0)

                        Button {
                            followsLiveTranscription = true
                            followLiveTranscript(using: proxy, force: true)
                        } label: {
                            Label(String(localized: "Follow Live"), systemImage: "arrow.down")
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: BardoLayout.playbackMaxWidth)
                    .padding(.horizontal, BardoLayout.playbackHorizontalPadding)
                    .frame(maxWidth: .infinity)
                    .padding(
                        .bottom,
                        BardoLayout.playbackBottomPadding
                            + BardoLayout.playbackSurfaceHeight
                            + BardoLayout.followLiveGapAbovePlayback
                    )
                }
            }
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

    private var isTranscribingThisRecording: Bool {
        model.isTranscribing && model.transcriptionRecordingID == recording.id
    }

    private var liveSegmentCount: Int {
        guard isTranscribingThisRecording,
              let live = model.liveTranscription,
              live.recordingID == recording.id else {
            return 0
        }
        return live.segments.count
    }

    private var transcriptionLiveView: some View {
        VStack(alignment: .leading, spacing: 18) {
            transcriptionLiveStatus

            if let live = model.liveTranscription, live.recordingID == recording.id {
                let paragraphs = buildParagraphs(from: live.segments)

                if !paragraphs.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(paragraphs) { paragraph in
                            TranscriptParagraphRow(
                                paragraph: paragraph,
                                playback: playback,
                                canEdit: false,
                                usesKaraoke: false,
                                onEditSegment: { _ in }
                            )
                        }
                    }

                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Continuando la transcripción…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if !live.provisionalText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(live.provisionalText)
                            .font(.body)
                            .lineSpacing(4)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(String(localized: "Texto provisional"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "La transcripción aparecerá aquí en cuanto Bardo reconozca las primeras palabras."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var transcriptionLiveStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label {
                Text(transcriptionStageText(model.transcriptionProgress?.stage))
                    .font(.callout.weight(.semibold))
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 12)

            Button(String(localized: "Cancel"), role: .cancel) {
                model.cancelTranscription()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func followLiveTranscript(using proxy: ScrollViewProxy, force: Bool = false) {
        guard isTranscribingThisRecording, force || followsLiveTranscription else { return }

        let scroll = {
            proxy.scrollTo(LiveTranscriptAnchor.tail, anchor: .bottom)
        }
        if reduceMotion {
            scroll()
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                scroll()
            }
        }
    }

    private var diarizationProgressView: some View {
        SpeakerIdentificationProgressView(
            progress: model.diarizationProgress,
            cancelAction: { model.cancelDiarization() }
        )
    }

    private var emptyTranscriptView: some View {
        BardoEmptyState(
            systemImage: "waveform.and.mic",
            title: String(localized: "No Transcript Yet"),
            detail: String(localized: "Transcribe this recording to search the conversation, identify participants, and create meeting minutes."),
            footnote: String(localized: "Processed locally on this Mac")
        ) {
            Button {
                model.beginTranscription()
            } label: {
                Label(
                    recording.processingState == .failed
                        ? String(localized: "Retry Transcription")
                        : String(localized: "Transcribe"),
                    systemImage: "waveform"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(recording.audioAssets.isEmpty || model.isDiarizing)
        }
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

private enum LiveTranscriptAnchor {
    static let tail = "bardo.transcript.live.tail"
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

    var timedWords: [TranscriptWord] {
        segments.flatMap(\.words)
    }

    var endTime: TimeInterval {
        segments.last?.endTime ?? startTime
    }
}

private struct TranscriptParagraphRow: View {
    let paragraph: TranscriptParagraph
    @ObservedObject var playback: AudioPlaybackController
    let canEdit: Bool
    var usesKaraoke: Bool = true
    let onEditSegment: (TranscriptSegment) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                playback.seek(to: paragraph.startTime)
                _ = playback.play()
            } label: {
                Text(LibraryFormatting.duration(paragraph.startTime))
                    .font(
                        .caption
                            .monospacedDigit()
                            .weight(isActivePlaybackParagraph ? .medium : .regular)
                    )
                    .foregroundStyle(
                        isActivePlaybackParagraph
                            ? Color.primary
                            : Color.secondary.opacity(0.72)
                    )
                    .frame(width: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.1), value: isActivePlaybackParagraph)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(!playback.isLoaded)
            .help(
                String.localizedStringWithFormat(
                    String(localized: "Play from %@"),
                    LibraryFormatting.duration(paragraph.startTime)
                )
            )

            VStack(alignment: .leading, spacing: 4) {
                paragraphText
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

    private var isActivePlaybackParagraph: Bool {
        let hasEnteredParagraph = playback.position > paragraph.startTime + 0.02
        return playback.position >= paragraph.startTime
            && playback.position <= paragraph.endTime
            && (playback.isPlaying || hasEnteredParagraph)
    }

    @ViewBuilder
    private var paragraphText: some View {
        if !usesKaraoke || paragraph.hasEdits || paragraph.timedWords.isEmpty {
            Text(paragraph.fullText)
                .font(.body)
                .lineSpacing(4)
        } else {
            KaraokeTranscriptText(
                words: paragraph.timedWords,
                fallbackText: paragraph.fullText,
                playbackPosition: playback.position,
                isPlaying: playback.isPlaying,
                paragraphStart: paragraph.startTime,
                paragraphEnd: paragraph.endTime
            )
        }
    }

    private func segmentMenuTitle(_ segment: TranscriptSegment) -> String {
        let compactText = segment.displayText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(42)
        return "\(LibraryFormatting.duration(segment.startTime)) · \(compactText)"
    }
}


private struct KaraokeTranscriptText: View {
    let words: [TranscriptWord]
    let fallbackText: String
    let playbackPosition: TimeInterval
    let isPlaying: Bool
    let paragraphStart: TimeInterval
    let paragraphEnd: TimeInterval

    var body: some View {
        if words.isEmpty {
            Text(fallbackText)
                .font(.body)
                .lineSpacing(4)
        } else {
            BardoWordFlowLayout(horizontalSpacing: 4, verticalSpacing: 5) {
                ForEach(words) { word in
                    Text(word.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body.weight(isSpokenOrCurrent(word) ? .medium : .regular))
                        .foregroundStyle(color(for: word))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.linear(duration: 0.08), value: playbackPosition)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(fallbackText)
        }
    }

    private var isActiveParagraph: Bool {
        let hasEnteredParagraph = playbackPosition > paragraphStart + 0.02
        return playbackPosition >= paragraphStart
            && playbackPosition <= paragraphEnd
            && (isPlaying || hasEnteredParagraph)
    }

    private func isSpokenOrCurrent(_ word: TranscriptWord) -> Bool {
        guard isActiveParagraph else { return false }
        return playbackPosition >= word.startTime
    }

    private func color(for word: TranscriptWord) -> Color {
        if isSpokenOrCurrent(word) {
            return .primary
        }
        return .secondary.opacity(0.72)
    }
}

private struct BardoWordFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 5

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let requiredWidth = currentX == 0 ? size.width : currentX + horizontalSpacing + size.width

            if requiredWidth > maxWidth, currentX > 0 {
                widestLine = max(widestLine, currentX)
                currentY += lineHeight + verticalSpacing
                currentX = size.width
                lineHeight = size.height
            } else {
                if currentX > 0 {
                    currentX += horizontalSpacing
                }
                currentX += size.width
                lineHeight = max(lineHeight, size.height)
            }
        }

        widestLine = max(widestLine, currentX)
        return CGSize(
            width: proposal.width ?? widestLine,
            height: currentY + lineHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = currentX == bounds.minX
                ? currentX + size.width
                : currentX + horizontalSpacing + size.width

            if nextX > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            } else if currentX > bounds.minX {
                currentX += horizontalSpacing
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            currentX += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct SpeakerIdentificationProgressView: View {
    let progress: DiarizationProgressSnapshot?
    let cancelAction: () -> Void

    private var fractionCompleted: Double {
        min(1, max(0, progress?.fractionCompleted ?? 0))
    }

    private var step: Int {
        switch progress?.stage {
        case .preparingModel, nil: 1
        case .loadingModel: 2
        case .diarizing: 3
        case .saving: 4
        }
    }

    private var detail: String {
        switch progress?.stage {
        case .preparingModel:
            String(localized: "Preparing SpeakerKit and checking the local speaker models.")
        case .loadingModel:
            String(localized: "Loading the speaker models into local memory.")
        case .diarizing:
            String(localized: "Analyzing the recording and grouping speech by voice.")
        case .saving:
            String(localized: "Applying the detected speaker labels to the transcript.")
        case nil:
            String(localized: "Starting local speaker analysis.")
        }
    }

    private var progressLabel: String {
        let percentage = Int((fractionCompleted * 100).rounded())
        return String.localizedStringWithFormat(
            String(localized: "Step %lld of 4 · %lld%%"),
            step,
            percentage
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label {
                        Text(diarizationStageText(progress?.stage))
                            .font(.callout.weight(.semibold))
                    } icon: {
                        Image(systemName: "person.2.wave.2")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }

                    Spacer(minLength: 12)

                    Text(progressLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: fractionCompleted)
                    .progressViewStyle(.linear)
                    .animation(.easeOut(duration: 0.16), value: fractionCompleted)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    Button(String(localized: "Cancel"), role: .cancel, action: cancelAction)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(diarizationStageText(progress?.stage)). \(progressLabel). \(detail)"
        )
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