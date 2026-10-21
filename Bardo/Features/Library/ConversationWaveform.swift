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
        /// Who is speaking on each side here, once speakers are known.
        var upperTint: Color?
        var lowerTint: Color?
    }

    /// The line between the halves, as a thin tube of Liquid Glass tinted by whoever is
    /// heard: orange where the Mac sounds, blue where you speak, flowing from one colour
    /// into the other through the pauses. What has been heard fills with colour and a
    /// steady glow; what is ahead stays inactive grey, like a slider's track.
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
        let samples = samples.sorted { $0.x < $1.x }
        let colors = blendedColors(of: samples, upperTint: upperTint, lowerTint: lowerTint, singleTint: singleTint, in: canvas.environment)

        func shading(_ stop: (Int, VoiceSample) -> Color) -> GraphicsContext.Shading {
            var stops = samples.enumerated().map { index, sample in
                Gradient.Stop(color: stop(index, sample), location: min(1, max(0, sample.x / size.width)))
            }
            // Where there is no audio, before it starts or after it ends, the line fades out.
            let first = stops[0], last = stops[stops.count - 1]
            stops.insert(.init(color: first.color.opacity(0), location: max(0, first.location - 0.01)), at: 0)
            stops.append(.init(color: last.color.opacity(0), location: min(1, last.location + 0.01)))
            return .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
        }
        let isHeard = { (sample: VoiceSample) in sample.emphasis >= 1 }

        let middle = size.height / 2
        let thickness: CGFloat = 3
        let tube = Path(roundedRect: CGRect(x: 0, y: middle - thickness / 2, width: size.width, height: thickness), cornerRadius: thickness / 2)

        // A steady glow, only along what has been heard.
        var glow = canvas
        glow.addFilter(.blur(radius: 3))
        glow.fill(
            Path(CGRect(x: 0, y: middle - 2.5, width: size.width, height: 5)),
            with: shading { index, sample in isHeard(sample) ? colors[index].opacity(0.22) : .clear }
        )
        // The glass: coloured where heard, inactive grey ahead, like a slider's track.
        canvas.fill(tube, with: shading { index, sample in isHeard(sample) ? colors[index].opacity(0.95) : Color.gray.opacity(0.35) })
        // Its reflections: a bright edge along the top and a soft shade underneath.
        canvas.fill(
            Path(roundedRect: CGRect(x: 0, y: middle - thickness / 2 + 0.25, width: size.width, height: 0.9), cornerRadius: 0.45),
            with: shading { _, sample in .white.opacity(isHeard(sample) ? 0.6 : 0.22) }
        )
        canvas.fill(
            Path(CGRect(x: 0, y: middle + thickness / 2 - 0.8, width: size.width, height: 0.8)),
            with: shading { _, sample in .black.opacity(isHeard(sample) ? 0.25 : 0.1) }
        )
    }

    /// Each point's colour: the blend of the two sides by how loud each is there, and of
    /// who is speaking. A pause takes its colour from the voices around it, and the
    /// colours are blended over a couple of seconds, so one flows into the next.
    private static func blendedColors(
        of samples: [VoiceSample],
        upperTint: Color,
        lowerTint: Color,
        singleTint: Color,
        in environment: EnvironmentValues
    ) -> [Color] {
        let hasTwoSides = samples.contains { $0.lower != nil }
        var mix: [Double?] = samples.map { sample in
            guard hasTwoSides else { return 0 }
            let lower = sample.lower ?? 0
            let total = sample.upper + lower
            return total > 0.06 ? Double(lower / total) : nil
        }
        // Fill the pauses from the nearest voices on each side.
        var previous: (index: Int, value: Double)?
        var nextKnown = [(index: Int, value: Double)?](repeating: nil, count: mix.count)
        var upcoming: (index: Int, value: Double)?
        for index in mix.indices.reversed() {
            if let value = mix[index] { upcoming = (index, value) }
            nextKnown[index] = upcoming
        }
        for index in mix.indices {
            if let value = mix[index] {
                previous = (index, value)
                continue
            }
            switch (previous, nextKnown[index]) {
            case let (before?, after?):
                let progress = Double(index - before.index) / Double(after.index - before.index)
                mix[index] = before.value + (after.value - before.value) * progress
            case let (before?, nil): mix[index] = before.value
            case let (nil, after?): mix[index] = after.value
            case (nil, nil): mix[index] = 0.5
            }
        }

        // Mixed as light, then softened with a wide bell so speakers fade into each other.
        let raw: [SIMD3<Double>] = samples.indices.map { index in
            let sample = samples[index]
            let upper = (sample.upperTint ?? (hasTwoSides ? upperTint : singleTint)).resolve(in: environment)
            let lower = (sample.lowerTint ?? lowerTint).resolve(in: environment)
            let t = Float(mix[index] ?? 0.5)
            return SIMD3(
                Double(upper.red + (lower.red - upper.red) * t),
                Double(upper.green + (lower.green - upper.green) * t),
                Double(upper.blue + (lower.blue - upper.blue) * t)
            )
        }
        let radius = 10
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * 25)) }
        return raw.indices.map { index in
            var total = SIMD3<Double>(repeating: 0)
            var weight = 0.0
            for (offset, w) in zip(-radius...radius, weights) {
                let neighbour = index + offset
                guard raw.indices.contains(neighbour) else { continue }
                total += raw[neighbour] * w
                weight += w
            }
            let color = total / weight
            return Color(.sRGBLinear, red: color.x, green: color.y, blue: color.z)
        }
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
    /// Once speakers are identified, each stretch takes the colour of who is speaking.
    var transcript: Transcript?

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
            .overlay {
                if duration > 0 {
                    PlayheadKnob(isGrabbed: scrubOrigin != nil)
                        .position(x: proxy.size.width * Self.anchor, y: proxy.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
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
            let speakers = transcript.map { SpeakerLanes(transcript: $0, splitsSides: lanes.lower != nil) }
            let count = lanes.upper.count
            let barDuration = duration / Double(count)
            let first = max(0, Int((position - Double(center) / Self.pointsPerSecond) / barDuration) - 1)
            let last = min(count - 1, Int((position + Double(size.width - center) / Self.pointsPerSecond) / barDuration) + 1)
            if first <= last {
                for index in first...last {
                    let time = Double(index) * barDuration
                    let barX = x(time)
                    // What has been heard reads in full colour; what is ahead, dimmed.
                    let opacity = barX + Style.barWidth <= center ? 1 : 0.32
                    let upperTint = speakers?.color(at: time, side: .upper)
                        ?? (lanes.lower == nil ? recording.waveformTint : Style.systemTint)
                    let lowerTint = speakers?.color(at: time, side: .lower) ?? Style.microphoneTint
                    voices.append(Style.VoiceSample(
                        x: barX + Style.barWidth / 2,
                        upper: CGFloat(lanes.upper[index]),
                        lower: lanes.lower.map { CGFloat($0[index]) },
                        emphasis: opacity,
                        upperTint: upperTint,
                        lowerTint: lowerTint
                    ))
                    if let lower = lanes.lower {
                        Style.drawBar(in: &bars, x: barX, level: CGFloat(lanes.upper[index]), direction: -1, size: size, color: upperTint.opacity(opacity))
                        Style.drawBar(in: &bars, x: barX, level: CGFloat(lower[index]), direction: 1, size: size, color: lowerTint.opacity(opacity))
                    } else {
                        Style.drawBar(in: &bars, x: barX, level: CGFloat(lanes.upper[index]), direction: 0, size: size, color: upperTint.opacity(opacity))
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
    }
}

/// Where a saved recording is, as the player bar's slider shows it: a white pill that
/// turns into a lens of Liquid Glass while it is held to scrub.
private struct PlayheadKnob: View {
    let isGrabbed: Bool

    var body: some View {
        Group {
            if #available(macOS 26.0, *), isGrabbed {
                Capsule()
                    .fill(.clear)
                    .frame(width: 34, height: 20)
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                Capsule()
                    .fill(.white)
                    .frame(width: 22, height: 13)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: isGrabbed)
    }
}

/// Who is speaking along a recording, in their transcript colours, on each side of the
/// line: you below it when the microphone has its own track, everyone else above.
struct SpeakerLanes {
    enum Side { case upper, lower }

    private struct Span {
        let start: TimeInterval
        let end: TimeInterval
        let color: Color
    }

    private var upper: [Span] = []
    private var lower: [Span] = []

    init(transcript: Transcript, splitsSides: Bool) {
        for segment in transcript.segments.sorted(by: { $0.startTime < $1.startTime }) {
            guard let speakerID = segment.speakerID else { continue }
            let span = Span(start: segment.startTime, end: segment.endTime, color: SpeakerPalette.color(for: speakerID, in: transcript))
            let isYou = segment.source == .microphone || transcript.speaker(withID: speakerID)?.role == .localUser
            if splitsSides, isYou {
                lower.append(span)
            } else {
                upper.append(span)
            }
        }
    }

    /// The colour of whoever is speaking on that side; in a pause, of whoever is
    /// closer, since a passage's first sound often comes a moment before its timing.
    func color(at time: TimeInterval, side: Side) -> Color? {
        let spans = side == .upper ? upper : lower
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return spans.first?.color }
        let current = spans[low - 1]
        if time > current.end, low < spans.count, spans[low].start - time < time - current.end {
            return spans[low].color
        }
        return current.color
    }
}
