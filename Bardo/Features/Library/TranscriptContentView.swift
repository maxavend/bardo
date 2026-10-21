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
    /// Read by the speaker labels; observed so a new name in Settings shows at once.
    @AppStorage(LocalSpeakerName.defaultsKey) private var localSpeakerName = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLiveTranscription = true
    /// When each live passage started revealing; passages already on screen have none.
    @State private var liveRevealStarts: [TranscriptSegment.ID: Date] = [:]
    @State private var liveRevealCursor = Date.distantPast

    var bottomContentInset: CGFloat = 0

    var body: some View {
        Group {
            if showsEmptyState {
                emptyTranscriptView
            } else {
                transcriptViewport
            }
        }
        .enableInjection()
    }

    /// A saved conversation that has no transcript and none on the way.
    private var showsEmptyState: Bool {
        !isTranscribingThisRecording && (model.transcript?.recordingID != recording.id)
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
            .onChange(of: liveSegmentIDs) { previous, current in
                scheduleReveal(of: current, after: previous)
            }
            .onChange(of: recording.id) { _, _ in
                liveRevealStarts = [:]
                liveRevealCursor = .distantPast
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
        .bardoTopBar {
            if isTranscribingThisRecording && hasLiveText {
                transcriptionLiveStatus
                    .frame(maxWidth: BardoLayout.detailContentMaxWidth, alignment: .leading)
                    .padding(.horizontal, BardoSpacing.detailHorizontal)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
            }
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
            .bardoSecondaryAction()
            .disabled(recording.audioAssets.isEmpty || model.isTranscribing || model.isDiarizing)

        case .singleSpeaker:
            Label(String(localized: "1 Speaker"), systemImage: "person")
                .foregroundStyle(.secondary)

        case .participants(let count):
            Button {
                isSpeakerNamingPresented = true
            } label: {
                HStack(spacing: 8) {
                    ParticipantAvatars(transcript: transcript)
                    Text(String.localizedStringWithFormat(String(localized: "%lld Participants"), count))
                }
            }
            .bardoSecondaryAction()
            .help("Escuchar, nombrar y fusionar a los participantes")
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
            // Before the first words the status fills the space; afterwards it is pinned
            // above the transcript (see `transcriptViewport`) so it never scrolls away.
            if !hasLiveText {
                transcriptionLiveStatus
            }

            if let live = model.liveTranscription, live.recordingID == recording.id {
                if !live.segments.isEmpty {
                    // Each recognised passage resolves into place once, as it arrives;
                    // the text itself stays plain so frequent updates remain cheap.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(live.segments) { segment in
                            LiveTranscriptSegmentRow(segment: segment, revealStart: liveRevealStarts[segment.id])
                        }
                    }

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
                }
            }
        }
    }

    private var transcriptionLiveStatus: some View {
        TranscriptionProgressPanel(
            progress: model.transcriptionProgress,
            live: model.liveTranscription?.recordingID == recording.id ? model.liveTranscription : nil,
            stageStartedAt: model.transcriptionStageStartedAt,
            isCompact: hasLiveText,
            cancelAction: { model.cancelTranscription() }
        )
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

    private var hasLiveText: Bool {
        guard let live = model.liveTranscription, live.recordingID == recording.id else { return false }
        return !live.segments.isEmpty || !live.provisionalText.isEmpty
    }

    private var liveSegmentIDs: [TranscriptSegment.ID] {
        guard let live = model.liveTranscription, live.recordingID == recording.id else { return [] }
        return live.segments.map(\.id)
    }

    /// Passages that arrive together start revealing a beat apart rather than waiting for
    /// each other, so no row ever sits on screen with a timestamp and no words.
    private func scheduleReveal(of current: [TranscriptSegment.ID], after previous: [TranscriptSegment.ID]) {
        guard !reduceMotion, let live = model.liveTranscription, live.recordingID == recording.id else { return }
        let known = Set(previous)
        let now = Date.now
        var cursor = liveRevealCursor > now.addingTimeInterval(2) ? now : max(now, liveRevealCursor)
        for segment in live.segments where !known.contains(segment.id) && liveRevealStarts[segment.id] == nil {
            liveRevealStarts[segment.id] = cursor
            cursor = cursor.addingTimeInterval(0.15)
        }
        liveRevealCursor = cursor
    }

    private var diarizationProgressView: some View {
        SpeakerIdentificationProgressView(
            progress: model.diarizationProgress,
            cancelAction: { model.cancelDiarization() }
        )
    }

    /// The recording's waveform, what a transcript gives, and one large button to make
    /// it, centered in the column.
    private var emptyTranscriptView: some View {
        // Take exactly the column's space: without a scroll view, the split view would
        // lay the column out at this content's ideal height, taller than the window.
        GeometryReader { proxy in
            emptyTranscriptContent(height: proxy.size.height)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// The waveform takes a good share of the height, as in the recorder; the player
    /// bar below shows the times.
    private func emptyTranscriptContent(height: CGFloat) -> some View {
        VStack(spacing: 28) {
            transcriptErrors

            if !recording.audioAssets.isEmpty {
                RecordingWaveform(recording: recording, playback: playback)
                    .frame(height: min(320, max(120, height * 0.38)))
            }

            VStack(spacing: 8) {
                Text(recording.processingState == .failed ? "No se pudo transcribir esta conversación" : "Aún no hay transcripción")
                    .font(.title3.weight(.semibold))
                Text(
                    model.transcriptionBlocker(for: recording.id)
                        ?? (recording.audioAssets.isEmpty
                            ? "Esta conversación no tiene un audio que se pueda transcribir."
                            : recording.processingState == .failed
                                ? "La última transcripción no terminó. El audio está a salvo y puedes intentarlo de nuevo."
                                : "Bardo la transcribe de forma privada en este Mac para que puedas leerla, buscar dentro de ella e identificar a los hablantes.")
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            }

            transcribeButton
        }
        .frame(maxWidth: BardoLayout.detailContentMaxWidth)
        .padding(.horizontal, BardoSpacing.detailHorizontal)
        .padding(.bottom, bottomContentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcribeButton: some View {
        let button = Button {
            model.beginTranscription()
        } label: {
            Text(recording.processingState == .failed ? "Intentar de nuevo" : "Transcribir")
                .padding(.horizontal, 14)
        }
        .disabled(recording.audioAssets.isEmpty || model.transcriptionBlocker(for: recording.id) != nil)

        return Group {
            if #available(macOS 26.0, *) {
                button
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
            } else {
                button
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
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
        let paragraphs = buildParagraphs(from: transcript.segments)

        if transcript.segments.isEmpty {
            ContentUnavailableView(
                "No encontramos voz",
                systemImage: "text.bubble",
                description: Text("El audio terminó de procesarse, pero no encontramos una conversación que se pudiera transcribir.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            let placement = TranscriptNotePlacement(notes: recording.notes, paragraphStarts: paragraphs.map(\.startTime))
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(placement.leadingMoments) { moment in
                    momentRow(moment)
                }
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
                            speakerChoices: transcript.speakers.map { speaker in
                                TranscriptSpeakerChoice(id: speaker.id, label: transcript.displayName(for: speaker))
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
                    // A section's name heads the first paragraph it covers; a moment
                    // follows the paragraph during which it was marked.
                    .modifier(TranscriptNotesAround(
                        sections: placement.sections(before: index),
                        moments: placement.moments(after: index),
                        sectionHeading: sectionHeading,
                        momentRow: momentRow
                    ))
                }
                ForEach(placement.trailingSections) { section in
                    sectionHeading(section)
                }
            }
        }
    }

    private func sectionHeading(_ section: RecordingSection) -> AnyView {
        AnyView(
            Button {
                playback.seek(to: section.start)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(section.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(LibraryFormatting.duration(section.start))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .help("Ir al inicio de esta sección")
            .accessibilityAddTraits(.isHeader)
        )
    }

    private func momentRow(_ moment: RecordingMoment) -> AnyView {
        AnyView(
            Button {
                playback.seek(to: moment.time)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // The moment's mark, as on the waveform.
                    Circle()
                        .fill(ConversationWaveformStyle.momentTint)
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(moment.title)
                                .fontWeight(.semibold)
                            Text(LibraryFormatting.duration(moment.time))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let note = moment.note {
                            Text(note)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 10))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Ir a este momento")
        )
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
        guard let speaker = transcript.speaker(withID: speakerID) else { return nil }
        return .speaker(speaker, fallbackName: transcript.defaultName(for: speaker))
    }

    private func speakerLabel(for speakerID: Speaker.ID?, in transcript: Transcript) -> String {
        guard let speaker = transcript.speaker(withID: speakerID) else {
            return transcript.speakers.isEmpty
                ? String(localized: "Transcript")
                : String(localized: "Unassigned Speaker")
        }
        return transcript.displayName(for: speaker)
    }
}

/// Distinct, system-adaptive colours that make speaker turns easy to scan. The name
/// always accompanies the colour, so it never carries meaning on its own.
/// The first participants as overlapping circles in their colours, with an initial
/// once they have a name, as Messages shows a group.
private struct ParticipantAvatars: View {
    let transcript: Transcript

    var body: some View {
        HStack(spacing: -5) {
            ForEach(transcript.speakers.prefix(4)) { speaker in
                Circle()
                    .fill(SpeakerPalette.color(for: speaker.id, in: transcript).gradient)
                    .frame(width: 18, height: 18)
                    .overlay {
                        if let initial = speaker.name?.nonEmptyTrimmed?.first {
                            Text(String(initial).uppercased())
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}

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

/// One passage of the transcript while Whisper is still listening.
private struct LiveTranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let revealStart: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LibraryFormatting.duration(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.72))
                .frame(width: 44, alignment: .trailing)

            StreamingRevealText(text: segment.displayText, revealStart: revealStart)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum LiveTranscriptAnchor {
    static let tail = "bardo.transcript.live.tail"
}

/// Places section headings above a paragraph and moments below it.
private struct TranscriptNotesAround: ViewModifier {
    let sections: [RecordingSection]
    let moments: [RecordingMoment]
    let sectionHeading: (RecordingSection) -> AnyView
    let momentRow: (RecordingMoment) -> AnyView

    func body(content: Content) -> some View {
        if sections.isEmpty && moments.isEmpty {
            content
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { sectionHeading($0) }
                content
                ForEach(moments) { momentRow($0) }
            }
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

/// Where playback is relative to a paragraph. A row redraws only when this changes, not
/// on each of the player's ten position reports a second.
private enum ParagraphPlayback: Equatable {
    case ahead
    case active
    case heard
}

private struct TranscriptParagraphRow: View {
    let paragraph: TranscriptParagraph
    /// Not observed: the row follows playback through `playbackPhase` alone.
    let playback: AudioPlaybackController
    let canEdit: Bool
    var searchQuery: String = ""
    var usesKaraoke: Bool = true
    var speakerChoices: [TranscriptSpeakerChoice] = []
    let onEditSegment: (TranscriptSegment) -> Void
    var onAssignSpeaker: ((Speaker.ID) -> Void)? = nil

    @State private var playbackPhase = ParagraphPlayback.ahead
    @State private var canPlay = false

    var body: some View {
        rowContent
            .onReceive(playback.$position) { phase(at: $0, isPlaying: playback.isPlaying) }
            .onReceive(playback.$isPlaying) { phase(at: playback.position, isPlaying: $0) }
            .onReceive(playback.$duration) { _ in
                // Published before it is set; read once it is.
                DispatchQueue.main.async { if canPlay != playback.isLoaded { canPlay = playback.isLoaded } }
            }
    }

    private func phase(at position: TimeInterval, isPlaying: Bool) {
        let hasEntered = position > paragraph.startTime + 0.02
        let phase: ParagraphPlayback
        if position >= paragraph.startTime, position <= paragraph.endTime, isPlaying || hasEntered {
            phase = .active
        } else {
            phase = position > paragraph.endTime ? .heard : .ahead
        }
        if phase != playbackPhase { playbackPhase = phase }
    }

    private var rowContent: some View {
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
            .disabled(!canPlay)
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
            .disabled(!canPlay)

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
        playbackPhase == .active
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
                playback: isActivePlaybackParagraph ? playback : nil
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

/// A paragraph's words as one piece of text. Only the paragraph being heard follows
/// the player, lighting the current word and dimming those still ahead; every other
/// paragraph is plain text that never redraws with playback.
private struct KaraokeTranscriptText: View {
    let words: [TranscriptWord]
    let fallbackText: String
    /// Set only while this paragraph is being heard.
    let playback: AudioPlaybackController?

    var body: some View {
        if words.isEmpty {
            Text(fallbackText)
                .font(.body)
                .lineSpacing(4)
        } else if let playback {
            LiveKaraokeText(words: words, playback: playback)
        } else {
            Text(Self.text(of: words, at: nil))
                .font(.body)
                .lineSpacing(4)
                .accessibilityLabel(fallbackText)
        }
    }

    /// The words joined once, coloured by `position` when there is one. The same string
    /// either way, so a paragraph never reflows as it starts or stops playing.
    static func text(of words: [TranscriptWord], at position: TimeInterval?) -> AttributedString {
        var text = AttributedString()
        for (index, word) in words.enumerated() {
            var piece = AttributedString((index == 0 ? "" : " ") + word.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let position {
                if position >= word.startTime && position <= word.endTime {
                    piece.foregroundColor = .accentColor
                } else if position < word.startTime {
                    piece.foregroundColor = Color.secondary.opacity(0.78)
                }
            }
            text += piece
        }
        return text
    }
}

/// The paragraph being heard, following the player word by word.
private struct LiveKaraokeText: View {
    let words: [TranscriptWord]
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        Text(KaraokeTranscriptText.text(of: words, at: playback.position))
            .font(.body)
            .lineSpacing(4)
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

private func diarizationStageText(_ stage: DiarizationStage?) -> String {
    switch stage {
    case .preparingModel: "Preparando la identificación…"
    case .loadingModel: "Dejando todo listo…"
    case .diarizing: "Identificando a los hablantes…"
    case .saving: "Organizando la transcripción…"
    case nil: "Preparando la identificación…"
    }
}
