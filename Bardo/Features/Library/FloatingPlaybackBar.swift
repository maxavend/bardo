import SwiftUI

struct FloatingPlaybackBar: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var playback: AudioPlaybackController

    @State private var isVolumePresented = false

    var body: some View {
        VStack(spacing: 8) {
            if let errorMessage = playback.errorMessage, !playback.isLoaded {
                errorBanner(errorMessage)
            }

            playerContent
                .frame(height: 46)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .bardoPlaybackSurface()
                .frame(maxWidth: BardoLayout.playbackMaxWidth)
        }
        .padding(.horizontal, BardoLayout.playbackHorizontalPadding)
        .padding(.bottom, BardoLayout.playbackBottomPadding)
        .frame(maxWidth: .infinity)
        .enableInjection()
    }

    private var playerContent: some View {
        HStack(spacing: 14) {
            transportControls

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(LibraryFormatting.recordingTitle(recording))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .help(LibraryFormatting.recordingTitle(recording))

                    Spacer(minLength: 8)

                    Text(LibraryFormatting.duration(playback.position))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text("/")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(LibraryFormatting.duration(playback.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { playback.position },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.01)
                )
                .controlSize(.mini)
                .disabled(!playback.isLoaded)
                .accessibilityLabel("Posición de reproducción")
                .accessibilityValue(LibraryFormatting.duration(playback.position))
            }
            .layoutPriority(1)

            Divider()
                .frame(height: 24)

            playbackRateMenu

            Button {
                isVolumePresented.toggle()
            } label: {
                Label("Volumen", systemImage: volumeSymbol)
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help("Volumen")
            .popover(isPresented: $isVolumePresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Volumen")
                        .font(.headline)
                    HStack(spacing: 8) {
                        Image(systemName: "speaker")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(playback.volume) },
                                set: { playback.setVolume(Float($0)) }
                            ),
                            in: 0...1
                        )
                        .frame(width: 150)
                        Image(systemName: "speaker.wave.3")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .controlSize(.regular)
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            transportButton(
                systemImage: "gobackward.15",
                accessibilityLabel: "Retroceder 15 segundos",
                action: { playback.seek(to: playback.position - 15) }
            )

            playPauseButton

            transportButton(
                systemImage: "goforward.15",
                accessibilityLabel: "Avanzar 15 segundos",
                action: { playback.seek(to: playback.position + 15) }
            )
        }
    }

    private var playPauseButton: some View {
        Button {
            playback.togglePlayback()
        } label: {
            Label(
                playback.isPlaying ? "Pausar" : "Reproducir",
                systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
            )
            .labelStyle(.iconOnly)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(!playback.isLoaded)
        .help(playback.isPlaying ? "Pausar" : "Reproducir")
        .accessibilityLabel(playback.isPlaying ? "Pausar" : "Reproducir")
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                Button {
                    playback.setPlaybackRate(Float(value))
                } label: {
                    if abs(Double(playback.playbackRate) - value) < 0.01 {
                        Label("\(rateLabel(value))×", systemImage: "checkmark")
                    } else {
                        Text("\(rateLabel(value))×")
                    }
                }
            }
        } label: {
            Text("\(rateLabel(Double(playback.playbackRate)))×")
                .font(.caption.weight(.medium))
                .frame(minWidth: 30)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!playback.isLoaded)
        .help("Velocidad de reproducción")
    }

    private var volumeSymbol: String {
        if playback.volume <= 0.01 { return "speaker.slash" }
        if playback.volume < 0.35 { return "speaker.wave.1" }
        if playback.volume < 0.7 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }

    private func rateLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 2)))
    }

    private func errorBanner(_ message: String) -> some View {
        GroupBox {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label("No se puede reproducir este audio", systemImage: "exclamationmark.triangle")
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
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(!playback.isLoaded)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
