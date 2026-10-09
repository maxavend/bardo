import SwiftUI

struct FloatingPlaybackBar: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var playback: AudioPlaybackController

    @State private var isVolumePresented = false
    @State private var availableWidth: CGFloat = .infinity

    /// Speed and volume step aside before the timeline gets too short to scrub.
    private var showsSecondaryControls: Bool { availableWidth >= 440 }
    private var showsTimes: Bool { availableWidth >= 300 }

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
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        }
        .padding(.horizontal, BardoLayout.playbackHorizontalPadding)
        .padding(.bottom, BardoLayout.playbackBottomPadding)
        .frame(maxWidth: .infinity)
        .enableInjection()
    }

    private var playerContent: some View {
        HStack(spacing: 14) {
            transportControls

            // The title is already the document's heading; the bar is for time.
            HStack(spacing: 10) {
                if showsTimes {
                    Text(LibraryFormatting.duration(playback.position))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { playback.position },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.01)
                )
                .controlSize(.small)
                .disabled(!playback.isLoaded)
                .accessibilityLabel("Posición de reproducción")
                .accessibilityValue(
                    "\(LibraryFormatting.duration(playback.position)) de \(LibraryFormatting.duration(playback.duration))"
                )

                if showsTimes {
                    Text(LibraryFormatting.duration(playback.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .leading)
                }
            }
            .layoutPriority(1)

            if showsSecondaryControls {
                secondaryControls
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var secondaryControls: some View {
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
