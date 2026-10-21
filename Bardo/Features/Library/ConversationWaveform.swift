import SwiftUI

/// How Bardo draws every conversation, live or saved: the Mac's audio rises above one
/// shared line in orange and your voice falls below it in blue; a single track fills
/// both sides. Moments are an orange hairline with a dot on top, sections a quiet hairline,
/// and the playhead a line with a dot at each end.
enum ConversationWaveformStyle {
    static let barWidth: CGFloat = 2
    static let step: CGFloat = 4
    /// Space kept clear on each side of the line, so the halves never touch.
    static let gap: CGFloat = 3
    static let microphoneTint = Color.blue
    static let systemTint = Color.orange
    static let momentTint = Color.orange
    static let dotSize: CGFloat = 6

    static func drawCenterLine(in canvas: inout GraphicsContext, size: CGSize, trailingInset: CGFloat = 0) {
        canvas.fill(
            Path(CGRect(x: 0, y: size.height / 2 - 0.25, width: size.width - trailingInset, height: 0.5)),
            with: .color(.secondary.opacity(0.35))
        )
    }

    /// What the line between the halves shows at one point: how loud each side is
    /// there, and how lit that stretch is (heard or ahead).
    struct VoiceSample {
        var x: CGFloat
        var upper: CGFloat
        /// Nil when one track fills both sides.
        var lower: CGFloat?
        var emphasis: Double = 1
    }

    /// The line between the halves takes the colour of whoever is heard at each
    /// moment: orange where the Mac sounds, blue where you speak, the two blended where
    /// both do, and barely there in silence, glowing softly where it is loud.
    static func drawVoiceLine(
        in canvas: inout GraphicsContext,
        size: CGSize,
        samples: [VoiceSample],
        upperTint: Color = systemTint,
        lowerTint: Color = microphoneTint,
        singleTint: Color = .accentColor
    ) {
        guard size.width > 0, !samples.isEmpty else {
            drawCenterLine(in: &canvas, size: size)
            return
        }
        let stops = samples
            .sorted { $0.x < $1.x }
            .map { sample -> Gradient.Stop in
                let loudness = max(sample.upper, sample.lower ?? 0)
                let color: Color
                if let lower = sample.lower {
                    let total = sample.upper + lower
                    color = total > 0.01 ? upperTint.mix(with: lowerTint, by: Double(lower / total)) : upperTint
                } else {
                    color = singleTint
                }
                let alpha = (0.08 + 0.92 * min(1, Double(loudness) * 1.3)) * sample.emphasis
                return .init(color: color.opacity(alpha), location: min(1, max(0, sample.x / size.width)))
            }
        // Where there is no audio, before it starts or after it ends, the line fades out.
        let first = stops.first!, last = stops.last!
        let edges = [Gradient.Stop(color: first.color.opacity(0), location: max(0, first.location - 0.01))]
            + stops
            + [Gradient.Stop(color: last.color.opacity(0), location: min(1, last.location + 0.01))]
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: edges),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: size.width, y: 0)
        )
        let middle = size.height / 2
        var glow = canvas
        glow.addFilter(.blur(radius: 4))
        glow.opacity = 0.7
        glow.fill(Path(CGRect(x: 0, y: middle - 2.5, width: size.width, height: 5)), with: shading)
        canvas.fill(Path(roundedRect: CGRect(x: 0, y: middle - 0.75, width: size.width, height: 1.5), cornerRadius: 0.75), with: shading)
    }

    /// One bar: `direction` -1 above the line, 1 below it, 0 on both sides.
    static func drawBar(
        in canvas: inout GraphicsContext,
        x: CGFloat,
        level: CGFloat,
        direction: CGFloat,
        size: CGSize,
        color: Color
    ) {
        let middle = size.height / 2
        let reach = (direction == 0 ? middle : middle - gap) - dotSize
        let height = pow(level, 2) * reach
        // Room noise leaves the line clean instead of dotting it.
        guard height > 2 else { return }
        let rect: CGRect = switch direction {
        case ..<0: CGRect(x: x, y: middle - gap - height, width: barWidth, height: height)
        case 0: CGRect(x: x, y: middle - height, width: barWidth, height: height * 2)
        default: CGRect(x: x, y: middle + gap, width: barWidth, height: height)
        }
        canvas.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
    }

    /// A moment: a hairline through the waveform with a dot where it starts.
    static func drawMoment(in canvas: inout GraphicsContext, x: CGFloat, size: CGSize) {
        canvas.fill(Path(CGRect(x: x - 0.5, y: dotSize, width: 1, height: size.height - dotSize)), with: .color(momentTint.opacity(0.6)))
        canvas.fill(Path(ellipseIn: CGRect(x: x - dotSize / 2, y: 0, width: dotSize, height: dotSize)), with: .color(momentTint))
    }

    /// Where a section starts: a quiet hairline, with its name when there is room.
    static func drawSection(in canvas: inout GraphicsContext, x: CGFloat, size: CGSize, title: String?) {
        canvas.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.secondary.opacity(0.35)))
        if let title {
            canvas.draw(
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary),
                at: CGPoint(x: x + 5, y: 0),
                anchor: .topLeading
            )
        }
    }

    /// Where a saved recording is playing: a small dot on the line, with a soft halo so
    /// it reads over the bars.
    static func drawPosition(in canvas: inout GraphicsContext, x: CGFloat, size: CGSize) {
        let middle = size.height / 2
        let halo = dotSize + 6
        canvas.fill(
            Path(ellipseIn: CGRect(x: x - halo / 2, y: middle - halo / 2, width: halo, height: halo)),
            with: .color(.black.opacity(0.25))
        )
        let dot = dotSize + 2
        canvas.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: middle - dot / 2, width: dot, height: dot)), with: .color(.white))
    }

    static func drawPlayhead(in canvas: inout GraphicsContext, x: CGFloat, size: CGSize, color: Color) {
        let dot = dotSize
        canvas.fill(Path(CGRect(x: x - 0.75, y: dot / 2, width: 1.5, height: size.height - dot)), with: .color(color))
        canvas.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: 0, width: dot, height: dot)), with: .color(color))
        canvas.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: size.height - dot, width: dot, height: dot)), with: .color(color))
    }
}

extension Recording {
    /// The colour of a recording drawn on one track: blue for the microphone, orange for
    /// the Mac's audio, and the accent for imported audio.
    var waveformTint: Color {
        if sources == [.microphone] { return ConversationWaveformStyle.microphoneTint }
        if sources == [.systemAudio] { return ConversationWaveformStyle.systemTint }
        return .accentColor
    }
}

/// A saved recording drawn like the recorder, close up: the audio glides under a fixed
/// point as it plays, what has been heard in full colour and what is ahead dimmed, with
/// its moments and sections passing by. The player bar below keeps the whole recording.
/// Drag to scrub, click to jump.
struct RecordingWaveform: View {
    let recording: Recording
    @ObservedObject var playback: AudioPlaybackController
    var matches: [TimeInterval] = []
    /// Draws section names along the top; the full player has its own lane for them.
    var labelsSections = true

    @StateObject private var overview = AudioWaveformOverviewModel()
    @State private var scrubOrigin: TimeInterval?

    /// How much audio one bar stands for: close enough to see a sentence's shape, so the
    /// window shows about a minute.
    static let secondsPerBar: TimeInterval = 0.25
    static let pointsPerSecond = ConversationWaveformStyle.step / secondsPerBar
    /// Where the current moment sits, as a share of the width.
    static let anchor: CGFloat = 0.5

    private var duration: TimeInterval {
        playback.duration > 0 ? playback.duration : (recording.duration ?? 0)
    }

    private var resolution: Int {
        // One bar per quarter second keeps the bars evenly spaced at any length.
        min(24_000, max(1, Int((duration / Self.secondsPerBar).rounded())))
    }

    /// Where `time` is drawn while `position` plays at the anchor.
    static func x(for time: TimeInterval, at position: TimeInterval, width: CGFloat) -> CGFloat {
        width * anchor + CGFloat(time - position) * pointsPerSecond
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { canvas, size in
                draw(in: &canvas, size: size)
            }
            .contentShape(.rect)
            .gesture(scrubGesture(width: proxy.size.width))
        }
        .onAppear { overview.load(playback.loadedTracks, resolution: resolution) }
        .onChange(of: playback.duration) { _, _ in overview.load(playback.loadedTracks, resolution: resolution) }
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

    /// Dragging moves the audio under the point, as in Voice Memos; a click jumps to
    /// what was clicked.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0, abs(value.translation.width) > 2 else { return }
                let origin = scrubOrigin ?? playback.position
                scrubOrigin = origin
                playback.seek(to: clamped(origin - Double(value.translation.width / Self.pointsPerSecond)))
            }
            .onEnded { value in
                defer { scrubOrigin = nil }
                guard duration > 0, scrubOrigin == nil else { return }
                let offset = Double((value.location.x - width * Self.anchor) / Self.pointsPerSecond)
                playback.seek(to: clamped(playback.position + offset))
            }
    }

    private func clamped(_ time: TimeInterval) -> TimeInterval {
        min(max(0, time), duration)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize) {
        typealias Style = ConversationWaveformStyle
        let position = playback.position
        let center = size.width * Self.anchor
        func x(_ time: TimeInterval) -> CGFloat { Self.x(for: time, at: position, width: size.width) }

        var bars = canvas
        // The audio fades in and out at the edges instead of being cut off.
        bars.clipToLayer { layer in
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                )
            )
        }
        var voices: [Style.VoiceSample] = []
        if let lanes = overview.lanes?.normalized, duration > 0, !lanes.upper.isEmpty {
            let count = lanes.upper.count
            let barDuration = duration / Double(count)
            let first = max(0, Int((position - Double(center) / Self.pointsPerSecond) / barDuration) - 1)
            let last = min(count - 1, Int((position + Double(size.width - center) / Self.pointsPerSecond) / barDuration) + 1)
            if first <= last {
                for index in first...last {
                    let barX = x(Double(index) * barDuration)
                    // What has been heard reads in full colour; what is ahead, dimmed.
                    let opacity = barX + Style.barWidth <= center ? 1 : 0.32
                    voices.append(Style.VoiceSample(
                        x: barX + Style.barWidth / 2,
                        upper: CGFloat(lanes.upper[index]),
                        lower: lanes.lower.map { CGFloat($0[index]) },
                        emphasis: opacity
                    ))
                    if let lower = lanes.lower {
                        Style.drawBar(in: &bars, x: barX, level: CGFloat(lanes.upper[index]), direction: -1, size: size, color: Style.systemTint.opacity(opacity))
                        Style.drawBar(in: &bars, x: barX, level: CGFloat(lower[index]), direction: 1, size: size, color: Style.microphoneTint.opacity(opacity))
                    } else {
                        Style.drawBar(in: &bars, x: barX, level: CGFloat(lanes.upper[index]), direction: 0, size: size, color: recording.waveformTint.opacity(opacity))
                    }
                }
            }
        }

        Style.drawVoiceLine(in: &bars, size: size, samples: voices, singleTint: recording.waveformTint)

        for section in recording.notes.sections where (0...size.width).contains(x(section.start)) {
            Style.drawSection(in: &bars, x: x(section.start), size: size, title: labelsSections ? section.title : nil)
        }
        for moment in recording.notes.moments where (0...size.width).contains(x(moment.time)) {
            Style.drawMoment(in: &bars, x: x(moment.time), size: size)
        }
        for match in matches where (0...size.width).contains(x(match)) {
            bars.fill(
                Path(roundedRect: CGRect(x: x(match) - 2, y: size.height - 4, width: 4, height: 4), cornerRadius: 2),
                with: .color(.yellow)
            )
        }
        // Where the recording is: one quiet dot on the line.
        if duration > 0 {
            Style.drawPosition(in: &canvas, x: center, size: size)
        }
    }
}
