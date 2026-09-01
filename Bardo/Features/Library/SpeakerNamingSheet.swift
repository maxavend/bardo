import AppKit
import SwiftUI

@MainActor
struct SpeakerNamingSheet: View {
    let transcript: Transcript
    let audioURL: URL?
    let onSave: ([Speaker.ID: String]) -> Void
    let onSkip: () -> Void

    @StateObject private var previewPlayback = AudioPlaybackController()
    @State private var names: [Speaker.ID: String]
    @State private var activeSpeakerID: Speaker.ID?
    @State private var activeClip: SpeakerPreviewClip?
    @State private var previewAudioAvailable = false
    @State private var previewMonitorTask: Task<Void, Never>?

    init(
        transcript: Transcript,
        audioURL: URL?,
        onSave: @escaping ([Speaker.ID: String]) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.transcript = transcript
        self.audioURL = audioURL
        self.onSave = onSave
        self.onSkip = onSkip
        _names = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: transcript.speakers.map { speaker in
                    (speaker.id, speaker.name ?? "")
                }
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(transcript.speakers.enumerated()), id: \.element.id) { index, speaker in
                        speakerRow(speaker, index: index)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 500)

            Divider()

            HStack(spacing: 12) {
                Button("Skip for Now") {
                    stopPreview(unload: true)
                    onSkip()
                }

                Spacer()

                Button("Done") {
                    stopPreview(unload: true)
                    onSave(names)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 560)
        .frame(minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadPreviewAudio)
        .onDisappear {
            stopPreview(unload: true)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 26, weight: .medium))
                .frame(width: 38, height: 38)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Who’s speaking?")
                    .font(.title2.weight(.semibold))

                Text("Listen to a short sample from each detected voice, then add the names you recognize.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder
    private func speakerRow(_ speaker: Speaker, index: Int) -> some View {
        let clip = SpeakerPreviewClipSelector.clip(
            for: speaker.id,
            in: transcript.segments,
            maximumDuration: 10
        )
        let isActive = activeSpeakerID == speaker.id

        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(defaultSpeakerName(index: index))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 86, alignment: .leading)

                    TextField("Name this speaker", text: nameBinding(for: speaker.id))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(defaultSpeakerName(index: index))
                }

                if let clip, previewAudioAvailable {
                    HStack(spacing: 10) {
                        Button {
                            togglePreview(for: speaker.id, clip: clip)
                        } label: {
                            Image(systemName: isActive && previewPlayback.isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(isActive && previewPlayback.isPlaying ? "Pause Sample" : "Play Sample")
                        .accessibilityLabel(isActive && previewPlayback.isPlaying ? "Pause Sample" : "Play Sample")

                        SpeakerPreviewTimeline(
                            timeline: previewPlayback.timeline,
                            clip: clip,
                            isActive: isActive
                        )
                    }
                } else {
                    Label(
                        clip == nil ? "No clear sample available" : "Audio sample unavailable",
                        systemImage: clip == nil ? "waveform.slash" : "speaker.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func nameBinding(for speakerID: Speaker.ID) -> Binding<String> {
        Binding(
            get: { names[speakerID] ?? "" },
            set: { names[speakerID] = $0 }
        )
    }

    private func defaultSpeakerName(index: Int) -> String {
        String(
            format: LibraryFormatting.localized("Speaker %@"),
            String(index + 1)
        )
    }

    private func loadPreviewAudio() {
        guard let audioURL else {
            previewAudioAvailable = false
            return
        }
        previewAudioAvailable = previewPlayback.load(url: audioURL)
    }

    private func togglePreview(for speakerID: Speaker.ID, clip: SpeakerPreviewClip) {
        if activeSpeakerID == speakerID, activeClip == clip {
            if previewPlayback.isPlaying {
                previewPlayback.pause()
                previewMonitorTask?.cancel()
                previewMonitorTask = nil
            } else {
                if previewPlayback.position < clip.startTime || previewPlayback.position >= clip.endTime {
                    previewPlayback.seek(to: clip.startTime)
                }
                guard previewPlayback.play() else {
                    activeSpeakerID = nil
                    activeClip = nil
                    return
                }
                monitorPreview(clip)
            }
            return
        }

        previewMonitorTask?.cancel()
        previewMonitorTask = nil
        previewPlayback.pause()
        previewPlayback.seek(to: clip.startTime)
        activeSpeakerID = speakerID
        activeClip = clip

        guard previewPlayback.play() else {
            activeSpeakerID = nil
            activeClip = nil
            return
        }
        monitorPreview(clip)
    }

    private func monitorPreview(_ clip: SpeakerPreviewClip) {
        previewMonitorTask?.cancel()
        previewMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }

                if previewPlayback.position >= clip.endTime - 0.02 || !previewPlayback.isPlaying {
                    if previewPlayback.position >= clip.endTime - 0.02 {
                        previewPlayback.pause()
                        previewPlayback.seek(to: clip.startTime)
                        activeSpeakerID = nil
                        activeClip = nil
                    }
                    previewMonitorTask = nil
                    return
                }
            }
        }
    }

    private func stopPreview(unload: Bool) {
        previewMonitorTask?.cancel()
        previewMonitorTask = nil
        if unload {
            previewPlayback.unload()
            previewAudioAvailable = false
        } else {
            previewPlayback.pause()
        }
        activeSpeakerID = nil
        activeClip = nil
    }
}

private struct SpeakerPreviewTimeline: View {
    @ObservedObject var timeline: AudioPlaybackTimeline
    let clip: SpeakerPreviewClip
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: elapsed, total: max(clip.duration, 0.01))
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Speaker sample")
                .accessibilityValue("\(LibraryFormatting.duration(elapsed)) of \(LibraryFormatting.duration(clip.duration))")

            Text("\(LibraryFormatting.duration(elapsed)) / \(LibraryFormatting.duration(clip.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
    }

    private var elapsed: TimeInterval {
        guard isActive else { return 0 }
        return min(max(0, timeline.position - clip.startTime), clip.duration)
    }
}
