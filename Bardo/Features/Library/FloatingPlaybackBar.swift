import SwiftUI

struct FloatingPlaybackBar: View {
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        VStack(spacing: 6) {
            if let errorMessage = playback.errorMessage, !playback.isLoaded {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }

            PlaybackTimelineControls(
                playback: playback,
                timeline: playback.timeline
            )
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

private struct PlaybackTimelineControls: View {
    let playback: AudioPlaybackController
    @ObservedObject var timeline: AudioPlaybackTimeline

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playback.seek(to: timeline.position - 15)
            } label: {
                Image(systemName: "gobackward.15")
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help("Back 15 seconds")

            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help(playback.isPlaying ? "Pause" : "Play")

            Text(LibraryFormatting.duration(timeline.position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { timeline.position },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(timeline.duration, 0.01)
            )
            .disabled(!playback.isLoaded)
            .accessibilityLabel("Playback position")

            Text(LibraryFormatting.duration(timeline.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .leading)

            Button {
                playback.seek(to: timeline.position + 15)
            } label: {
                Image(systemName: "goforward.15")
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help("Forward 15 seconds")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .bardoGlassSurface(cornerRadius: 24, interactive: true)
    }
}
