import SwiftUI

struct FloatingPlaybackBar: View {
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        VStack(spacing: 6) {
            if let metadata = playback.metadata {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(metadata.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(metadata.trackLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Playing \(metadata.title), \(metadata.trackLabel)")
            }

            if let errorMessage = playback.errorMessage, !playback.isLoaded {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }

            HStack(spacing: 12) {
                Button {
                    playback.seek(to: playback.position - 15)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(.plain)
                .disabled(!playback.isLoaded)
                .accessibilityLabel("Back 15 seconds")
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
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Text(LibraryFormatting.duration(playback.position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 38, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { playback.position },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.01)
                )
                .disabled(!playback.isLoaded)
                .accessibilityLabel("Playback position")

                Text(LibraryFormatting.duration(playback.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 38, alignment: .leading)

                Button {
                    playback.seek(to: playback.position + 15)
                } label: {
                    Image(systemName: "goforward.15")
                }
                .buttonStyle(.plain)
                .disabled(!playback.isLoaded)
                .help("Forward 15 seconds")
                .accessibilityLabel("Forward 15 seconds")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .bardoGlassSurface(cornerRadius: 24, interactive: true)
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}
