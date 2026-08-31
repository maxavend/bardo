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
        .frame(maxWidth: 780)
        .padding(.horizontal, BardoDesignMetrics.spacingL)
        .padding(.vertical, BardoDesignMetrics.spacingS)
    }
}

private struct PlaybackTimelineControls: View {
    @ObservedObject var playback: AudioPlaybackController
    @ObservedObject var timeline: AudioPlaybackTimeline

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideControls
            compactControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .bardoGlassSurface(
            cornerRadius: BardoDesignMetrics.floatingCornerRadius,
            interactive: true
        )
        .accessibilityElement(children: .contain)
    }

    private var wideControls: some View {
        HStack(spacing: 10) {
            backButton
            playButton
            positionText
            scrubber
            durationText
            forwardButton
            speedMenu
        }
    }

    private var compactControls: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                backButton
                playButton
                Spacer(minLength: 4)
                positionText
                Text("/")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                durationText
                Spacer(minLength: 4)
                speedMenu
                forwardButton
            }

            scrubber
        }
    }

    private var backButton: some View {
        Button {
            playback.seek(to: timeline.position - 15)
        } label: {
            Image(systemName: "gobackward.15")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playback.isLoaded)
        .help("Back 15 seconds")
        .accessibilityLabel("Back 15 seconds")
    }

    private var playButton: some View {
        Button {
            playback.togglePlayback()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!playback.isLoaded)
        .help(playback.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
    }

    private var positionText: some View {
        Text(LibraryFormatting.duration(timeline.position))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 38, alignment: .trailing)
            .accessibilityLabel("Current time")
    }

    private var durationText: some View {
        Text(LibraryFormatting.duration(timeline.duration))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 38, alignment: .leading)
            .accessibilityLabel("Duration")
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { timeline.position },
                set: { playback.seek(to: $0) }
            ),
            in: 0...max(timeline.duration, 0.01)
        )
        .disabled(!playback.isLoaded)
        .accessibilityLabel("Playback position")
        .layoutPriority(1)
    }

    private var forwardButton: some View {
        Button {
            playback.seek(to: timeline.position + 15)
        } label: {
            Image(systemName: "goforward.15")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playback.isLoaded)
        .help("Forward 15 seconds")
        .accessibilityLabel("Forward 15 seconds")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(AudioPlaybackController.supportedPlaybackRates, id: \.self) { rate in
                Button {
                    playback.setPlaybackRate(rate)
                } label: {
                    if abs(playback.playbackRate - rate) < 0.001 {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(rateLabel(playback.playbackRate))
                .font(.caption.monospacedDigit().weight(.medium))
                .frame(minWidth: 34)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback Speed")
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(rateLabel(playback.playbackRate))
    }

    private func rateLabel(_ rate: Float) -> String {
        let value = Double(rate)
        if value.rounded() == value {
            return "\(Int(value))×"
        }
        return String(format: "%g×", value)
    }
}
