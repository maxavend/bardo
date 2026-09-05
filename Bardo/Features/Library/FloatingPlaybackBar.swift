import SwiftUI

struct FloatingPlaybackBar: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        VStack(spacing: BardoSpacing.small) {
            if let errorMessage = playback.errorMessage, !playback.isLoaded {
                errorBanner(errorMessage)
            }

            playerContent
                .frame(height: 42)
                .padding(.horizontal, BardoSpacing.standard)
                .padding(.vertical, BardoSpacing.small)
                .bardoPlaybackSurface()
                .frame(maxWidth: BardoLayout.playbackMaxWidth)
        }
        .padding(.horizontal, BardoLayout.playbackHorizontalPadding)
        .padding(.bottom, BardoLayout.playbackBottomPadding)
        .frame(maxWidth: .infinity)
        .enableInjection()
    }

    private var playerContent: some View {
        HStack(spacing: BardoSpacing.standard) {
            transportControls

            Image(systemName: LibraryFormatting.sourceSymbol(recording.sources))
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: BardoSpacing.xSmall) {
                HStack(alignment: .firstTextBaseline, spacing: BardoSpacing.compact) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LibraryFormatting.recordingTitle(recording))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .help(LibraryFormatting.recordingTitle(recording))

                        Text(LibraryFormatting.source(recording.sources))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }

                HStack(spacing: BardoSpacing.small) {
                    Text(LibraryFormatting.duration(playback.position))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)

                    Slider(
                        value: Binding(
                            get: { playback.position },
                            set: { playback.seek(to: $0) }
                        ),
                        in: 0...max(playback.duration, 0.01)
                    )
                    .controlSize(.mini)
                    .disabled(!playback.isLoaded)
                    .accessibilityLabel(String(localized: "Playback position"))
                    .accessibilityValue(LibraryFormatting.duration(playback.position))
                    .layoutPriority(1)

                    Text(LibraryFormatting.duration(playback.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                }
            }
            .layoutPriority(1)
        }
        .controlSize(.regular)
    }

    private var transportControls: some View {
        HStack(spacing: BardoSpacing.small) {
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
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
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
        .frame(maxWidth: BardoLayout.playbackMaxWidth)
    }

    private func transportButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(accessibilityLabel, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(!playback.isLoaded)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
