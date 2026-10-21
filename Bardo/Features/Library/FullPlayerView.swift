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
    @State private var matchIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordingDocumentHeader(recording: recording)
                .padding(.bottom, 24)

            PlayerTimeline(
                recording: recording,
                playback: playback,
                matches: matches.map(\.startTime),
                updateNotes: { change in Task { await model.updateNotes(recording.id, change) } }
            )

            HStack(spacing: 10) {
                Button {
                    Task { await model.updateNotes(recording.id) { $0.addMoment(at: playback.position, title: "", note: nil) } }
                } label: {
                    Label("Marcar momento aquí", systemImage: "flag")
                }
                Button {
                    Task { await model.updateNotes(recording.id) { $0.addSection(at: playback.position, title: "") } }
                } label: {
                    Label("Nueva sección aquí", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Spacer(minLength: 12)
                if !searchQuery.isEmpty {
                    searchNavigator
                }
            }
            .controlSize(.regular)
            .padding(.top, 14)

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
            ToolbarItem(placement: .primaryAction) {
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
                        )
                    )
                }
            }
        }
        .navigationTitle(LibraryFormatting.recordingTitle(recording))
        .onChange(of: searchQuery) { _, _ in matchIndex = 0 }
        #if DEBUG
        .onDesignReviewCommand { step in
            switch step.action {
            case "playerOptions": isOptionsPresented = true
            case "seek": playback.seek(to: TimeInterval(step.value) ?? 10)
            case "play": _ = playback.play()
            default: break
            }
        }
        #endif
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

    var body: some View {
        Form {
            Toggle(isOn: $skipsSilences) {
                Text("Omitir silencios")
                Text("Salta las pausas largas de esta grabación al reproducirla.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// What is being said now, as a subtitle: who speaks, and their words lighting up as
/// they are heard. Karaoke belongs to playback of finished transcripts only.
private struct KaraokeSubtitle: View {
    let transcript: Transcript
    @ObservedObject var playback: AudioPlaybackController

    /// After this long past its end, a passage gives way to silence.
    private static let linger: TimeInterval = 2

    var body: some View {
        let segment = currentSegment
        VStack(spacing: 12) {
            if let segment {
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
                Text(attributedText(for: segment))
                    .font(.title2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(segment.id)
                    .transition(.opacity)
            } else {
                Text(playback.isPlaying ? " " : "Reproduce para ver los subtítulos")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: segment?.id)
        .accessibilityElement(children: .combine)
    }

    private var currentSegment: TranscriptSegment? {
        let position = playback.position
        return transcript.segments
            .filter { $0.startTime <= position + 0.05 && position <= $0.endTime + Self.linger }
            .max { $0.startTime < $1.startTime }
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
                piece.font = .title2.weight(.bold)
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
