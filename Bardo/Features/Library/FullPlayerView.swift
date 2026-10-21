import SwiftUI

/// A whole recording in the whole window: its timeline with sections and moments to
/// edit, what is being said as subtitles while it plays, and the player.
struct FullPlayerView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    /// Not observed here: the timeline, the subtitles and the bar each follow it, so the
    /// whole player does not redraw ten times a second.
    let playback: AudioPlaybackController
    /// The window's search: matches show on the timeline and can be stepped through.
    let searchQuery: String
    let onClose: () -> Void

    @State private var isOptionsPresented = false
    /// A moment or section being named, opened as soon as it is made.
    @State private var editingMoment: RecordingMoment.ID?
    @State private var editingSection: RecordingSection.ID?
    @State private var silences: [ClosedRange<TimeInterval>]?
    @State private var matchIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordingDocumentHeader(recording: recording)
                .padding(.bottom, 24)

            PlayerTimeline(
                recording: recording,
                playback: playback,
                matches: matches.map(\.startTime),
                transcript: transcript,
                updateNotes: { change in Task { await model.updateNotes(recording.id, change) } },
                editingMoment: $editingMoment,
                editingSection: $editingSection
            )

            if !searchQuery.isEmpty {
                HStack {
                    Spacer()
                    searchNavigator
                }
                .padding(.top, 12)
            }

            // The words take the rest of the window and scroll within it, however long
            // a passage is; nothing above them ever moves.
            subtitles
                .frame(maxWidth: BardoLayout.detailContentMaxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 12)
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .bardoBottomBar {
            FloatingPlaybackBar(recording: recording, playback: playback)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onClose) {
                    Label("Volver a la biblioteca", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .help("Volver a la biblioteca (Esc)")
            }
            // The recording's own actions, where a conversation keeps its actions.
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: addMoment) {
                    Label("Momento", systemImage: "flag")
                }
                .accessibilityLabel("Marcar momento")
                .help("Marcar un momento donde va la reproducción")
                Button(action: addSection) {
                    Label("Sección", systemImage: "rectangle.split.2x1")
                }
                .accessibilityLabel("Nueva sección")
                .help("Empezar una sección donde va la reproducción")
                Button {
                    isOptionsPresented = true
                } label: {
                    Label("Opciones", systemImage: "slider.horizontal.3")
                }
                .help("Opciones de reproducción")
                .popover(isPresented: $isOptionsPresented, arrowEdge: .bottom) {
                    PlayerOptions(
                        skipsSilences: Binding(
                            get: { recording.skipsSilences },
                            set: { skips in Task { await model.setSkipsSilences(recording.id, skips) } }
                        ),
                        silences: silences
                    )
                    .task { silences = await model.longSilences(of: recording.id) }
                }
            }
        }
        .navigationTitle(LibraryFormatting.recordingTitle(recording))
        .onChange(of: searchQuery) { _, _ in matchIndex = 0 }
        #if DEBUG
        .onDesignReviewCommand { step in
            switch step.action {
            case "playerOptions": isOptionsPresented = true
            case "addMoment": addMoment()
            case "addSection": addSection()
            case "seek": playback.seek(to: TimeInterval(step.value) ?? 10)
            case "play": _ = playback.play()
            default: break
            }
        }
        #endif
    }

    // MARK: Notes

    /// Marks a moment where playback is and opens it to be named, as the recorder does.
    private func addMoment() {
        Task {
            var created: RecordingMoment.ID?
            await model.updateNotes(recording.id) { created = $0.addMoment(at: playback.position, title: "", note: nil).id }
            // Its dot appears first; the editor then points at it.
            try? await Task.sleep(for: .milliseconds(120))
            editingMoment = created
        }
    }

    /// Starts a section where playback is and opens it to be named.
    private func addSection() {
        Task {
            var created: RecordingSection.ID?
            await model.updateNotes(recording.id) { created = $0.addSection(at: playback.position, title: "").id }
            // Its name appears first; the editor then points at it.
            try? await Task.sleep(for: .milliseconds(120))
            editingSection = created
        }
    }

    // MARK: Search

    private var transcript: Transcript? {
        guard let transcript = model.transcript, transcript.recordingID == recording.id else { return nil }
        return transcript
    }

    private var matches: [TranscriptSegment] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let transcript else { return [] }
        return transcript.segments
            .filter { $0.displayText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.startTime < $1.startTime }
    }

    private var searchNavigator: some View {
        let matches = matches
        return HStack(spacing: 6) {
            if matches.isEmpty {
                Text("Sin resultados")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    jump(to: (matchIndex - 1 + matches.count) % matches.count, in: matches)
                } label: {
                    Label("Anterior", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                Text("\(min(matchIndex + 1, matches.count)) de \(matches.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    jump(to: (matchIndex + 1) % matches.count, in: matches)
                } label: {
                    Label("Siguiente", systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
            }
        }
        .font(.callout)
    }

    private func jump(to index: Int, in matches: [TranscriptSegment]) {
        matchIndex = index
        playback.seek(to: matches[index].startTime)
    }

    // MARK: Subtitles

    @ViewBuilder
    private var subtitles: some View {
        if let transcript {
            KaraokeSubtitle(transcript: transcript, playback: playback)
        } else {
            VStack(spacing: 8) {
                Text("Sin subtítulos todavía")
                    .font(.title3.weight(.semibold))
                Text("Transcribe la conversación para leer aquí lo que se dice mientras suena.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Per-recording playback options.
private struct PlayerOptions: View {
    @Binding var skipsSilences: Bool
    /// The pauses that would be skipped, once found.
    let silences: [ClosedRange<TimeInterval>]?

    var body: some View {
        Form {
            Toggle(isOn: $skipsSilences) {
                Text("Omitir silencios")
                Text(summary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
    /// What skipping would do in this recording, so its effect is known.
    private var summary: String {
        guard let silences else { return "Buscando las pausas de esta grabación…" }
        guard !silences.isEmpty else { return "Esta grabación no tiene pausas de más de 2 segundos." }
        let seconds = silences.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let pauses = silences.count == 1 ? "1 pausa" : "\(silences.count) pausas"
        return "Salta \(pauses) de más de 2 segundos: unos \(LibraryFormatting.duration(seconds)) menos."
    }
}

/// What is being said, as lyrics are in Music: every passage in one column that
/// follows the playback, the current one in full with its words lighting up as they are
/// heard, the others dimmed the further they are, and the column fading out at the top
/// and bottom. It scrolls freely without a scroll bar, picks up the playback again a
/// moment after, and a click on a passage plays from there. Karaoke belongs to playback
/// of finished transcripts only.
private struct KaraokeSubtitle: View {
    let transcript: Transcript
    /// Not observed: the column redraws when the passage changes; only the passage being
    /// heard follows each word.
    let playback: AudioPlaybackController

    @State private var index: Int?

    /// When the person last scrolled; the column waits before following again.
    @State private var scrolledAt: Date?
    @State private var viewportHeight: CGFloat = 400

    private static let followDelay: TimeInterval = 3

    private var segments: [TranscriptSegment] {
        transcript.segments
            .filter { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        let segments = segments
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 22) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { offset, segment in
                        passage(segment, offset: offset, current: index, previous: offset > 0 ? segments[offset - 1] : nil)
                            .id(segment.id)
                    }
                }
                // Room for the first and last passages to reach the middle.
                .padding(.vertical, viewportHeight * 0.4)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { scrolledAt = .now }
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.16),
                        .init(color: .black, location: 0.84),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onAppear {
                if let index { proxy.scrollTo(segments[index].id, anchor: .center) }
            }
            .onReceive(playback.$position) { position in
                let current = Self.currentIndex(in: segments, at: position)
                if current != index { index = current }
            }
            .onChange(of: index) { _, index in
                guard let index else { return }
                if let scrolledAt, Date().timeIntervalSince(scrolledAt) < Self.followDelay { return }
                withAnimation(.smooth(duration: 0.6)) {
                    proxy.scrollTo(segments[index].id, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func passage(_ segment: TranscriptSegment, offset: Int, current: Int?, previous: TranscriptSegment?) -> some View {
        let isCurrent = offset == current
        let distance = current.map { abs($0 - offset) } ?? 2
        VStack(spacing: 8) {
            // Who speaks, where the speaker changes.
            if segment.speakerID != previous?.speakerID || previous == nil {
                speaker(of: segment)
                    .opacity(isCurrent ? 1 : 0.6)
            }
            Group {
                if isCurrent {
                    HeardPassage(segment: segment, playback: playback)
                } else {
                    Text(segment.displayText)
                }
            }
            .font(isCurrent ? .title2.weight(.semibold) : .title3.weight(.medium))
            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .opacity(isCurrent ? 1 : max(0.35, 0.8 - Double(distance) * 0.15))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture {
            scrolledAt = nil
            playback.seek(to: segment.startTime)
        }
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.25), value: isCurrent)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Reproducir desde aquí")
    }

    @ViewBuilder
    private func speaker(of segment: TranscriptSegment) -> some View {
        if let speakerID = segment.speakerID, let speaker = transcript.speakers.first(where: { $0.id == speakerID }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(SpeakerPalette.color(for: speakerID, in: transcript))
                    .frame(width: 8, height: 8)
                Text(transcript.displayName(for: speaker))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The passage being heard; between passages, the last one heard stays.
    private static func currentIndex(in segments: [TranscriptSegment], at position: TimeInterval) -> Int? {
        segments.lastIndex { $0.startTime <= position + 0.05 } ?? (segments.isEmpty ? nil : 0)
    }
}

/// The passage being heard, its words lighting up as they are heard.
private struct HeardPassage: View {
    let segment: TranscriptSegment
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        Text(attributedText)
    }

    /// Heard words in full colour, the current one highlighted, the rest still dim.
    private var attributedText: AttributedString {
        guard !segment.words.isEmpty, segment.editedText == nil else {
            return AttributedString(segment.displayText)
        }
        let position = playback.position
        var text = AttributedString()
        for (index, word) in segment.words.enumerated() {
            var piece = AttributedString((index == 0 ? "" : " ") + word.text.trimmingCharacters(in: .whitespaces))
            if position >= word.startTime && position <= word.endTime {
                piece.foregroundColor = .accentColor
            } else if position > word.endTime {
                piece.foregroundColor = .primary
            } else {
                piece.foregroundColor = .secondary
            }
            text += piece
        }
        return text
    }
}
