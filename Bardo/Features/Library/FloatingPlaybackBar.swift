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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .bardoGlassCapsule(interactive: true)
                .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 6)
                .frame(maxWidth: 620)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .enableInjection()
    }

    private var playerContent: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
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
            }

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
            .controlSize(.small)
            .disabled(!playback.isLoaded)
            .accessibilityLabel(String(localized: "Playback position"))
            .accessibilityValue(LibraryFormatting.duration(playback.position))

            Text(LibraryFormatting.duration(playback.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
    }

    private var playPauseButton: some View {
        Button {
            playback.togglePlayback()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bardoPressable)
        .foregroundStyle(.primary)
        .disabled(!playback.isLoaded)
        .help(playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
        .accessibilityLabel(playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func transportButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bardoPressable)
        .foregroundStyle(.secondary)
        .disabled(!playback.isLoaded)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
