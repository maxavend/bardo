import SwiftUI

/// The whole recording at a glance: its loudness from start to end, with the playhead.
/// Click or drag anywhere to jump there.
struct RecordingWaveformOverview: View {
    @ObservedObject var playback: AudioPlaybackController
    var height: CGFloat = 56

    @StateObject private var overview = AudioWaveformOverviewModel()

    private let barWidth: CGFloat = 2
    private let step: CGFloat = 3

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                Canvas { canvas, size in
                    drawBars(in: &canvas, size: size)
                }
                .overlay(alignment: .leading) {
                    // Taller than the waveform, as in Voice Memos, so it reads at a glance.
                    if playback.duration > 0 {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 4, height: height + 12)
                            .offset(x: CGFloat(playback.position / playback.duration) * proxy.size.width - 2)
                    }
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            seek(toFraction: value.location.x / max(1, proxy.size.width))
                        }
                )
            }
            .frame(height: height)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))

            HStack {
                Text(LibraryFormatting.duration(0))
                Spacer()
                Text(LibraryFormatting.duration(playback.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onAppear { overview.load(playback.loadedTracks) }
        .onChange(of: playback.duration) { _, _ in overview.load(playback.loadedTracks) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Posición en la grabación"))
        .accessibilityValue(Text(LibraryFormatting.duration(playback.position)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.seek(to: playback.position + 10)
            case .decrement: playback.seek(to: playback.position - 10)
            @unknown default: break
            }
        }
    }

    private func seek(toFraction fraction: CGFloat) {
        guard playback.duration > 0 else { return }
        playback.seek(to: Double(min(1, max(0, fraction))) * playback.duration)
    }

    private func drawBars(in canvas: inout GraphicsContext, size: CGSize) {
        let count = max(1, Int(size.width / step))
        let middle = size.height / 2
        let reach = size.height / 2 - 6
        let levels = overview.levels ?? []
        for bar in 0..<count {
            // Each bar shows the loudest of the levels it covers.
            var level: Float = 0
            if !levels.isEmpty {
                let first = bar * levels.count / count
                let last = max(first + 1, (bar + 1) * levels.count / count)
                level = levels[first..<min(last, levels.count)].max() ?? 0
            }
            let half = max(0.75, pow(CGFloat(level), 1.6) * reach)
            let rect = CGRect(x: CGFloat(bar) * step, y: middle - half, width: barWidth, height: half * 2)
            canvas.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.primary.opacity(0.6)))
        }
    }
}
