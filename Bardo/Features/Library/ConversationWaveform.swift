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
        singleTint: Color = .accentColor,
        colors precomputed: [Color]? = nil
    ) {
        guard size.width > 0, !samples.isEmpty else {
            drawCenterLine(in: &canvas, size: size)
            return
        }
        // Saved recordings blend their colours once and pass them in, already in order.
        let colors = precomputed
            ?? blendedColors(of: samples, upperTint: upperTint, lowerTint: lowerTint, singleTint: singleTint, in: canvas.environment)

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
        // What has been heard is a tube of glass; what is ahead, a hairline track.
        let split = samples.first { !isHeard($0) }?.x ?? size.width
        var heard = canvas
        heard.clip(to: Path(CGRect(x: 0, y: 0, width: max(0, split), height: size.height)))
        var ahead = canvas
        ahead.clip(to: Path(CGRect(x: split, y: 0, width: max(0, size.width - split), height: size.height)))

        // A steady glow along what has been heard.
        var glow = heard
        glow.addFilter(.blur(radius: 3))
        glow.fill(
            Path(CGRect(x: 0, y: middle - 2.5, width: size.width, height: 5)),
            with: shading { index, _ in colors[index].opacity(0.22) }
        )
        // The glass, with its reflections: a bright edge along the top and a soft shade
        // underneath.
        heard.fill(
            Path(roundedRect: CGRect(x: 0, y: middle - thickness / 2, width: size.width, height: thickness), cornerRadius: thickness / 2),
            with: shading { index, _ in colors[index].opacity(0.95) }
        )
        heard.fill(
            Path(roundedRect: CGRect(x: 0, y: middle - thickness / 2 + 0.25, width: size.width, height: 0.9), cornerRadius: 0.45),
            with: shading { _, _ in .white.opacity(0.6) }
        )
        heard.fill(
            Path(CGRect(x: 0, y: middle + thickness / 2 - 0.8, width: size.width, height: 0.8)),
            with: shading { _, _ in .black.opacity(0.25) }
        )
        // The track ahead, like a slider's: thin and quiet.
        ahead.fill(
            Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)),
            with: shading { _, _ in Color.gray.opacity(0.22) }
        )
    }

    /// Each point's colour: the blend of the two sides by how loud each is there, and of
    /// who is speaking. A pause takes its colour from the voices around it, and the
    /// colours are blended over a couple of seconds, so one flows into the next.
    static func blendedColors(
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
        let height = pow(level, 2) * (middle - gap - dotSize)
        // Room noise leaves the line clean instead of dotting it.
        guard height > 2 else { return }
        // A single track mirrors on both sides; nothing ever crosses the line.
        if direction <= 0 {
            canvas.fill(Path(roundedRect: CGRect(x: x, y: middle - gap - height, width: barWidth, height: height), cornerRadius: barWidth / 2), with: .color(color))
        }
        if direction >= 0 {
            canvas.fill(Path(roundedRect: CGRect(x: x, y: middle + gap, width: barWidth, height: height), cornerRadius: barWidth / 2), with: .color(color))
        }
    }

    /// A moment: a hairline through the waveform with a dot where it starts.
    static func drawMoment(in canvas: inout GraphicsContext, x: CGFloat, size: CGSize) {
        // A flag on its pole: from the top down to the line, never through it.
        let pole = size.height / 2 - gap - dotSize
        canvas.fill(Path(CGRect(x: x - 0.5, y: dotSize, width: 1, height: max(0, pole))), with: .color(momentTint.opacity(0.6)))
        canvas.fill(Path(ellipseIn: CGRect(x: x - dotSize / 2, y: 0, width: dotSize, height: dotSize)), with: .color(momentTint))
    }

    /// Where a section starts: a quiet hairline down to the line, with its name when there
    /// is room, shortened with an ellipsis before it reaches the next section.
    static func drawSection(
        in canvas: inout GraphicsContext,
        x: CGFloat,
        size: CGSize,
        title: String?,
        maxWidth: CGFloat = .infinity
    ) {
        canvas.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: max(0, size.height / 2 - gap))), with: .color(.secondary.opacity(0.35)))
        guard let title, maxWidth > 24 else { return }
        func label(_ string: String) -> GraphicsContext.ResolvedText {
            canvas.resolve(Text(string).font(.caption2.weight(.medium)).foregroundStyle(.secondary))
        }
        var shown = title
        var resolved = label(shown)
        while resolved.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width > maxWidth, shown.count > 1 {
            shown = String(shown.dropLast(shown.hasSuffix("…") ? 2 : 1)).trimmingCharacters(in: .whitespaces) + "…"
            resolved = label(shown)
        }
        canvas.draw(resolved, at: CGPoint(x: x + 5, y: 0), anchor: .topLeading)
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

/// A saved recording drawn like the recorder, close up: the audio glides under the
/// playhead as it plays, what has been heard in full colour and what is ahead dimmed,
/// with its moments and sections passing by. At the start the playhead sets off from the
/// leading edge and at the end it runs to the trailing one, so the view is always full.
/// The player bar below keeps the whole recording. Drag to scrub, click to jump.
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
    /// The player reports its position ten times a second; between reports it is
    /// carried forward at the playback rate, so the audio glides at the display's pace.
    @State private var clock = PlaybackClock()
    @State private var paint = WaveformPaint()

    /// How much audio one bar stands for: close enough to see a sentence's shape, so the
    /// window shows about a minute.
    static let secondsPerBar: TimeInterval = 0.25
    static let pointsPerSecond = ConversationWaveformStyle.step / secondsPerBar
    /// Where the playhead rests while the audio glides, as a share of the width.
    static let anchor: CGFloat = 0.5
    /// Room at each end for the playhead pill.
    static let inset: CGFloat = 12

    private var duration: TimeInterval {
        playback.duration > 0 ? playback.duration : (recording.duration ?? 0)
    }

    private var resolution: Int {
        // One bar per quarter second keeps the bars evenly spaced at any length.
        min(24_000, max(1, Int((duration / Self.secondsPerBar).rounded())))
    }

    /// The first moment on screen while `position` plays: the playhead rests at the
    /// anchor, except near the ends, where the audio stops and the playhead moves.
    static func windowStart(at position: TimeInterval, duration: TimeInterval, width: CGFloat) -> TimeInterval {
        let visible = Double(max(1, width - inset * 2)) / pointsPerSecond
        let leading = Double(max(0, width * anchor - inset)) / pointsPerSecond
        return min(max(0, position - leading), max(0, duration - visible))
    }

    /// Where `time` is drawn while `position` plays.
    static func x(for time: TimeInterval, at position: TimeInterval, duration: TimeInterval, width: CGFloat) -> CGFloat {
        inset + CGFloat(time - windowStart(at: position, duration: duration, width: width)) * pointsPerSecond
    }

    var body: some View {
        GeometryReader { proxy in
            // Redrawn at the display's pace only while playing; still otherwise.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playback.isPlaying || scrubOrigin != nil)) { context in
                let position = clock.position(at: context.date, playback: playback, duration: duration)
                Canvas { canvas, size in
                    draw(in: &canvas, size: size, position: position)
                }
                .overlay(alignment: .topLeading) {
                    if duration > 0 {
                        PlayheadKnob(isGrabbed: scrubOrigin != nil)
                            .position(
                                x: Self.x(for: position, at: position, duration: duration, width: proxy.size.width),
                                y: proxy.size.height / 2
                            )
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(.rect)
            .gesture(scrubGesture(width: proxy.size.width))
        }
        .onAppear { overview.load(playback.loadedTracks, resolution: resolution) }
        .onChange(of: playback.duration) { _, _ in overview.load(playback.loadedTracks, resolution: resolution) }
        .onChange(of: playback.position, initial: true) { _, position in clock.sync(position) }
        .onChange(of: playback.isPlaying) { _, _ in clock.sync(playback.position) }
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

    /// Dragging moves the playhead like a slider's knob: to the right is later. A click
    /// jumps to what was clicked.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0, abs(value.translation.width) > 2 else { return }
                let origin = scrubOrigin ?? playback.position
                scrubOrigin = origin
                playback.seek(to: clamped(origin + Double(value.translation.width / Self.pointsPerSecond)))
            }
            .onEnded { value in
                defer { scrubOrigin = nil }
                guard duration > 0, scrubOrigin == nil else { return }
                let position = playback.position
                let start = Self.windowStart(at: position, duration: duration, width: width)
                playback.seek(to: clamped(start + Double((value.location.x - Self.inset) / Self.pointsPerSecond)))
            }
    }

    private func clamped(_ time: TimeInterval) -> TimeInterval {
        min(max(0, time), duration)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, position: TimeInterval) {
        typealias Style = ConversationWaveformStyle
        let start = Self.windowStart(at: position, duration: duration, width: size.width)
        let playhead = Self.x(for: position, at: position, duration: duration, width: size.width)
        func x(_ time: TimeInterval) -> CGFloat { Self.inset + CGFloat(time - start) * Self.pointsPerSecond }
        let visibleEnd = start + Double(size.width - Self.inset * 2) / Self.pointsPerSecond

        var bars = canvas
        // The audio fades out only where more of it continues past the edge.
        let leadingFade = start > 0.01 ? 0.1 : 0
        let trailingFade = visibleEnd < duration - 0.01 ? 0.9 : 1
        bars.clipToLayer { layer in
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: leadingFade > 0 ? .clear : .black, location: 0),
                        .init(color: .black, location: leadingFade),
                        .init(color: .black, location: trailingFade),
                        .init(color: trailingFade < 1 ? .clear : .black, location: 1)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                )
            )
        }

        guard let lanes = overview.lanes?.normalized, duration > 0, !lanes.upper.isEmpty else {
            Style.drawCenterLine(in: &bars, size: size)
            return
        }
        let colors = paint.colors(for: lanes, transcript: transcript, duration: duration, recording: recording, in: canvas.environment)
        let count = lanes.upper.count
        let barDuration = duration / Double(count)
        let first = max(0, Int(start / barDuration) - 1)
        let last = min(count - 1, Int(visibleEnd / barDuration) + 1)
        guard first <= last else { return }

        var voices: [Style.VoiceSample] = []
        voices.reserveCapacity(last - first + 1)
        for index in first...last {
            let barX = x(Double(index) * barDuration)
            // What has been heard reads in full colour; what is ahead, dimmed.
            let opacity = barX + Style.barWidth <= playhead ? 1 : 0.32
            voices.append(Style.VoiceSample(
                x: barX + Style.barWidth / 2,
                upper: CGFloat(lanes.upper[index]),
                lower: lanes.lower.map { CGFloat($0[index]) },
                emphasis: opacity
            ))
            if let lower = lanes.lower {
                Style.drawBar(in: &bars, x: barX, level: CGFloat(lanes.upper[index]), direction: -1, size: size, color: colors.upper[index].opacity(opacity))
                Style.drawBar(in: &bars, x: barX, level: CGFloat(lower[index]), direction: 1, size: size, color: colors.lower[index].opacity(opacity))
            } else {
                Style.drawBar(in: &bars, x: barX, level: CGFloat(lanes.upper[index]), direction: 0, size: size, color: colors.upper[index].opacity(opacity))
            }
        }
        Style.drawVoiceLine(in: &bars, size: size, samples: voices, colors: Array(colors.line[first...last]))

        let sections = recording.notes.sections.sorted { $0.start < $1.start }
        for (index, section) in sections.enumerated() where (0...size.width).contains(x(section.start)) {
            let next = index + 1 < sections.count ? x(sections[index + 1].start) : size.width
            Style.drawSection(
                in: &bars,
                x: x(section.start),
                size: size,
                title: labelsSections ? section.title : nil,
                maxWidth: next - x(section.start) - 14
            )
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

/// Carries the player's position forward between its reports, at the playback rate.
private struct PlaybackClock {
    private var reported: TimeInterval = 0
    private var reportedAt = Date()

    mutating func sync(_ position: TimeInterval) {
        reported = position
        reportedAt = Date()
    }

    @MainActor
    func position(at date: Date, playback: AudioPlaybackController, duration: TimeInterval) -> TimeInterval {
        guard playback.isPlaying else { return playback.position }
        // Never further ahead than one report, so a late report cannot pull it back much.
        let elapsed = min(0.2, max(0, date.timeIntervalSince(reportedAt)))
        return min(duration, reported + elapsed * Double(playback.playbackRate))
    }
}

/// The colours of a saved recording, worked out once: each bar's by who is speaking, and
/// the line's blend of the two sides. Drawing a frame then only reads them.
@MainActor
private final class WaveformPaint {
    struct Colors {
        var upper: [Color]
        var lower: [Color]
        var line: [Color]
    }

    private var key: (lanes: WaveformLanes, transcript: Transcript?, scheme: ColorScheme)?
    private var cached: Colors?

    func colors(
        for lanes: WaveformLanes,
        transcript: Transcript?,
        duration: TimeInterval,
        recording: Recording,
        in environment: EnvironmentValues
    ) -> Colors {
        if let cached, let key, key.lanes == lanes, key.transcript == transcript, key.scheme == environment.colorScheme {
            return cached
        }
        typealias Style = ConversationWaveformStyle
        let count = lanes.upper.count
        let barDuration = duration / Double(max(1, count))
        let speakers = transcript.map { SpeakerLanes(transcript: $0, splitsSides: lanes.lower != nil) }
        var upper: [Color] = []
        var lower: [Color] = []
        var samples: [Style.VoiceSample] = []
        upper.reserveCapacity(count)
        lower.reserveCapacity(count)
        samples.reserveCapacity(count)
        for index in 0..<count {
            let time = Double(index) * barDuration
            let upperTint = speakers?.color(at: time, side: .upper)
                ?? (lanes.lower == nil ? recording.waveformTint : Style.systemTint)
            let lowerTint = speakers?.color(at: time, side: .lower) ?? Style.microphoneTint
            upper.append(upperTint)
            lower.append(lowerTint)
            samples.append(Style.VoiceSample(
                x: CGFloat(index),
                upper: CGFloat(lanes.upper[index]),
                lower: lanes.lower.map { CGFloat($0[index]) },
                upperTint: upperTint,
                lowerTint: lowerTint
            ))
        }
        let line = Style.blendedColors(
            of: samples,
            upperTint: Style.systemTint,
            lowerTint: Style.microphoneTint,
            singleTint: recording.waveformTint,
            in: environment
        )
        let colors = Colors(upper: upper, lower: lower, line: line)
        key = (lanes, transcript, environment.colorScheme)
        cached = colors
        return colors
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
