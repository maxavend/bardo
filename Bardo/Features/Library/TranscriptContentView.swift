import AppKit
import SwiftUI

struct TranscriptContentView: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    /// Passed to the rows, which observe it; observing it here would rebuild every
    /// paragraph on each playhead tick.
    let playback: AudioPlaybackController

    /// Highlighted, never filtered: a match keeps the rest of the conversation around it.
    let searchQuery: String
    @Binding var editor: TranscriptEditorState?
    @Binding var isSpeakerNamingPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLiveTranscription = true

    var bottomContentInset: CGFloat = 0

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
            .onChange(of: searchQuery) { _, query in
                scrollToFirstMatch(of: query, using: proxy)
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
                        bottomContentInset > 0
                            ? BardoLayout.playbackBottomPadding
                                + BardoLayout.playbackSurfaceHeight
                                + BardoLayout.followLiveGapAbovePlayback
                            : BardoLayout.followLiveGapAbovePlayback
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
                .fixedSize()

            if transcript.segments.contains(where: { $0.editedText != nil }) {
                Label(String(localized: "Edited"), systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
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
                    // The status row above already shows progress.
                    Text(String(localized: "La transcripción aparecerá aquí en cuanto Bardo reconozca las primeras palabras."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var transcriptionLiveStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label {
                Text(transcriptionStatusText(model.transcriptionProgress))
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

    private func scrollToFirstMatch(of query: String, using proxy: ScrollViewProxy) {
        guard !query.isEmpty,
              let transcript = model.transcript,
              transcript.recordingID == recording.id,
              let paragraph = buildParagraphs(from: transcript.segments).first(where: { paragraph in
                  LibraryFormatting.containsSearchTerms(paragraph.fullText, query: query)
              }) else {
            return
        }
        if reduceMotion {
            proxy.scrollTo(paragraph.id, anchor: .center)
        } else {
            withAnimation(.smooth(duration: 0.3)) {
                proxy.scrollTo(paragraph.id, anchor: .center)
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
        ContentUnavailableView {
            Label(
                recording.processingState == .failed ? "No pudimos transcribir esta conversación" : "Aún no hay transcripción",
                systemImage: recording.processingState == .failed ? "exclamationmark.bubble" : "text.bubble"
            )
        } description: {
            Text(
                model.transcriptionBlocker(for: recording.id)
                    ?? (recording.audioAssets.isEmpty
                        ? "Esta conversación no tiene un audio que se pueda transcribir."
                        : recording.processingState == .failed
                            ? "La última transcripción no terminó. El audio está a salvo y puedes intentarlo de nuevo."
                            : "Bardo la transcribe de forma privada en este Mac para que puedas leerla, buscar dentro de ella e identificar a los hablantes.")
            )
        } actions: {
            Button(recording.processingState == .failed ? "Intentar de nuevo" : "Transcribir") {
                model.beginTranscription()
            }
            .buttonStyle(.borderedProminent)
            .disabled(recording.audioAssets.isEmpty || model.transcriptionBlocker(for: recording.id) != nil)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
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
        let paragraphs = buildParagraphs(from: transcript.segments)

        if transcript.segments.isEmpty {
            ContentUnavailableView(
                "No encontramos voz",
                systemImage: "text.bubble",
                description: Text("El audio terminó de procesarse, pero no encontramos una conversación que se pudiera transcribir.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(Array(paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                    let currentSpeaker = speakerLabel(for: paragraph.speakerID, in: transcript)
                    let previousSpeaker = index > 0
                        ? speakerLabel(for: paragraphs[index - 1].speakerID, in: transcript)
                        : nil
                    let startsSpeakerTurn = currentSpeaker != previousSpeaker

                    VStack(alignment: .leading, spacing: 6) {
                        if !transcript.speakers.isEmpty && (startsSpeakerTurn || index == 0) {
                            speakerHeader(speakerID: paragraph.speakerID, in: transcript)
                        }

                        TranscriptParagraphRow(
                            paragraph: paragraph,
                            playback: playback,
                            canEdit: !model.isTranscribing && !model.isDiarizing,
                            searchQuery: searchQuery,
                            speakerChoices: transcript.speakers.enumerated().map { index, speaker in
                                TranscriptSpeakerChoice(
                                    id: speaker.id,
                                    label: {
                                        let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                        return name.isEmpty
                                            ? String.localizedStringWithFormat(String(localized: "Speaker %lld"), index + 1)
                                            : name
                                    }()
                                )
                            },
                            onEditSegment: { segment in editor = .segment(segment) },
                            onAssignSpeaker: { speakerID in
                                Task {
                                    await model.assignTranscriptSegments(
                                        paragraph.segments.map(\.id),
                                        to: speakerID
                                    )
                                }
                            }
                        )
                    }
                    .padding(.top, startsSpeakerTurn && index > 0 ? 6 : 0)
                    .id(paragraph.id)
                }
            }
        }
    }

    @ViewBuilder
    private func speakerHeader(speakerID: Speaker.ID?, in transcript: Transcript) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(SpeakerPalette.color(for: speakerID, in: transcript))
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
}

/// Distinct, system-adaptive colours that make speaker turns easy to scan. The name
/// always accompanies the colour, so it never carries meaning on its own.
enum SpeakerPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

    static func color(for speakerID: Speaker.ID?, in transcript: Transcript) -> Color {
        guard let speakerID,
              let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else {
            return .secondary
        }
        return colors[index % colors.count]
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

private struct TranscriptSpeakerChoice: Identifiable {
    let id: Speaker.ID
    let label: String
}

private struct TranscriptParagraphRow: View {
    let paragraph: TranscriptParagraph
    @ObservedObject var playback: AudioPlaybackController
    let canEdit: Bool
    var searchQuery: String = ""
    var usesKaraoke: Bool = true
    var speakerChoices: [TranscriptSpeakerChoice] = []
    let onEditSegment: (TranscriptSegment) -> Void
    var onAssignSpeaker: ((Speaker.ID) -> Void)? = nil

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

            if canEdit, let onAssignSpeaker, !speakerChoices.isEmpty {
                Menu("Asignar hablante") {
                    ForEach(speakerChoices) { choice in
                        Button {
                            onAssignSpeaker(choice.id)
                        } label: {
                            if paragraph.speakerID == choice.id {
                                Label(choice.label, systemImage: "checkmark")
                            } else {
                                Text(choice.label)
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Copiar bloque") {
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
        if !searchQuery.isEmpty, LibraryFormatting.containsSearchTerms(paragraph.fullText, query: searchQuery) {
            Text(LibraryFormatting.highlighted(paragraph.fullText, matching: searchQuery, style: .findIndicator))
                .font(.body)
                .lineSpacing(4)
        } else if !usesKaraoke || paragraph.hasEdits || paragraph.timedWords.isEmpty {
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
            BardoWordFlowLayout(horizontalSpacing: 4, verticalSpacing: 2) {
                ForEach(words) { word in
                    Text(word.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body.weight(isCurrent(word) ? .medium : .regular))
                        .foregroundStyle(color(for: word))
                        .padding(.horizontal, isCurrent(word) ? 2 : 0)
                        .padding(.vertical, 1)
                        .background {
                            if isCurrent(word) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.14))
                            }
                        }
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

    private func isCurrent(_ word: TranscriptWord) -> Bool {
        guard isActiveParagraph else { return false }
        return playbackPosition >= word.startTime && playbackPosition <= word.endTime
    }

    private func color(for word: TranscriptWord) -> Color {
        guard isActiveParagraph else { return .primary }
        if isCurrent(word) {
            return Color.accentColor
        }
        if playbackPosition > word.endTime {
            return .primary
        }
        return .secondary.opacity(0.78)
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
            "Preparando la identificación de hablantes."
        case .loadingModel:
            "Dejando listo lo necesario para distinguir las voces."
        case .diarizing:
            "Escuchando la conversación y agrupando los fragmentos por voz."
        case .saving:
            "Organizando la transcripción con los hablantes encontrados."
        case nil:
            "Comenzando a identificar a los hablantes."
        }
    }

    private var progressLabel: String {
        let percentage = Int((fractionCompleted * 100).rounded())
        return String.localizedStringWithFormat(
            "Paso %lld de 4 · %lld%%",
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

                    Button("Cancelar", role: .cancel, action: cancelAction)
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

/// Model preparation can include a first download when setup was skipped or the
/// models were removed; show how far along it is.
private func transcriptionStatusText(_ progress: TranscriptionProgressSnapshot?) -> String {
    if let progress, progress.stage == .preparingModel,
       progress.fractionCompleted > 0, progress.fractionCompleted < 1 {
        let percentage = Int((progress.fractionCompleted * 100).rounded())
        return "Preparando lo necesario para transcribir · \(percentage) %"
    }
    return transcriptionStageText(progress?.stage)
}

private func transcriptionStageText(_ stage: TranscriptionStage?) -> String {
    switch stage {
    case .preparingModel: "Preparando la transcripción…"
    case .loadingModel: "Dejando todo listo…"
    case .transcribing: "Transcribiendo la conversación…"
    case .saving: "Guardando la transcripción…"
    case nil: "Preparando la transcripción…"
    }
}

private func diarizationStageText(_ stage: DiarizationStage?) -> String {
    switch stage {
    case .preparingModel: "Preparando la identificación…"
    case .loadingModel: "Dejando todo listo…"
    case .diarizing: "Identificando a los hablantes…"
    case .saving: "Organizando la transcripción…"
    case nil: "Preparando la identificación…"
    }
}
