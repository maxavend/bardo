import SwiftUI

struct FloatingPlaybackBar: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        VStack(spacing: 8) {
            if let errorMessage = playback.errorMessage, !playback.isLoaded {
                errorBanner(errorMessage)
            }

            playerContent
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .bardoGlassSurface(cornerRadius: BardoCornerRadius.floating, interactive: true)
                .frame(maxWidth: 760)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .enableInjection()
    }

    private var playerContent: some View {
        HStack(spacing: 12) {
            Text(LibraryFormatting.recordingTitle(recording))
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .help(LibraryFormatting.recordingTitle(recording))

            Divider()
                .frame(height: 20)

            transportButton(
                systemImage: "gobackward.15",
                accessibilityLabel: String(localized: "Back 15 seconds"),
                action: { playback.seek(to: playback.position - 15) }
            )

            playPauseButton

            transportButton(
                systemImage: "goforward.15",
                accessibilityLabel: String(localized: "Forward 15 seconds"),
                action: { playback.seek(to: playback.position + 15) }
            )

            Text(LibraryFormatting.duration(playback.position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { playback.position },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.01)
            )
            .disabled(!playback.isLoaded)
            .accessibilityLabel(String(localized: "Playback position"))
            .accessibilityValue(LibraryFormatting.duration(playback.position))

            Text(LibraryFormatting.duration(playback.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .controlSize(.regular)
    }

    private var playPauseButton: some View {
        Button {
            playback.togglePlayback()
        } label: {
            Label(
                playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
            )
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(!playback.isLoaded)
        .help(playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
        .accessibilityLabel(playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }

    private func errorBanner(_ message: String) -> some View {
        GroupBox {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label(String(localized: "Playback unavailable"), systemImage: "exclamationmark.triangle")
        }
        .frame(maxWidth: 760)
    }

    private func transportButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(accessibilityLabel, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(!playback.isLoaded)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}