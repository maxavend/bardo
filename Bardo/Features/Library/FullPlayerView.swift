import SwiftUI

/// A whole recording in the whole window: its timeline with sections and moments to
/// edit, what is being said as subtitles while it plays, and the player.
struct FullPlayerView: View {
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var playback: AudioPlaybackController
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

            Spacer(minLength: 24)

            subtitles
                .frame(maxWidth: BardoLayout.detailContentMaxWidth)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 24)
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

/// What is being said now, as lyrics are in Music: the current passage with its words
/// lighting up as they are heard, the one before and the one after dimmed around it.
/// Karaoke belongs to playback of finished transcripts only.
private struct KaraokeSubtitle: View {
    let transcript: Transcript
    @ObservedObject var playback: AudioPlaybackController

    private var segments: [TranscriptSegment] {
        transcript.segments
            .filter { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        let segments = segments
        let index = currentIndex(in: segments)
        VStack(spacing: 18) {
            if let index {
                if index > 0 {
                    line(segments[index - 1], emphasis: .before)
                }
                VStack(spacing: 8) {
                    speaker(of: segments[index])
                    Text(attributedText(for: segments[index]))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if index + 1 < segments.count {
                    line(segments[index + 1], emphasis: .after)
                }
            } else {
                Text(playback.isPlaying ? " " : "Reproduce para ver los subtítulos")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.25), value: index)
        .accessibilityElement(children: .combine)
    }

    private enum Emphasis { case before, after }

    private func line(_ segment: TranscriptSegment, emphasis: Emphasis) -> some View {
        Text(segment.displayText)
            .font(.title3.weight(.medium))
            .foregroundStyle(emphasis == .before ? .tertiary : .secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
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
    private func currentIndex(in segments: [TranscriptSegment]) -> Int? {
        let position = playback.position
        guard position > 0 || playback.isPlaying else { return nil }
        return segments.lastIndex { $0.startTime <= position + 0.05 }
    }

    /// Heard words in full colour, the current one highlighted, the rest still dim.
    private func attributedText(for segment: TranscriptSegment) -> AttributedString {
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
