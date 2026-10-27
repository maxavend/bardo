import SwiftUI

/// The microphones a recording can switch to while it runs.
struct LiveMicrophoneChoice {
    let devices: [AudioDevice]
    let selectedUID: String?
    let select: (AudioDevice) -> Void
}

/// One source of the recording in progress.
struct LiveRecorderTrack: Identifiable {
    let id: String
    let title: LocalizedStringKey
    /// The device it comes from, when Bardo knows it.
    let detail: String?
    let tint: Color
    let meter: LiveAudioMeter
    var choice: LiveMicrophoneChoice?

    /// Your voice, below the line, in the transcript's colour for you.
    static func microphone(_ meter: LiveAudioMeter, device: String?, choice: LiveMicrophoneChoice? = nil) -> LiveRecorderTrack {
        LiveRecorderTrack(id: "microphone", title: "Tu micrófono", detail: device, tint: .blue, meter: meter, choice: choice)
    }

    /// The Mac's audio, above the line, in the colour of the first other speaker.
    static func system(_ meter: LiveAudioMeter) -> LiveRecorderTrack {
        LiveRecorderTrack(id: "system", title: "Audio del Mac", detail: nil, tint: .orange, meter: meter)
    }
}

/// The detail column while Bardo records, laid out like the conversation it becomes: its
/// title, one live line where your voice rises above and the Mac's audio falls below,
/// and the time with pause and finish on a floating bar like the player's.
struct LiveRecorderView: View {
    let title: String
    let subtitle: String
    let tracks: [LiveRecorderTrack]
    let isPaused: Bool
    var warning: String?
    var pauseAction: (() -> Void)?
    var resumeAction: (() -> Void)?
    var isMicrophoneMuted = false
    var muteAction: (() -> Void)?
    var notes = RecordingNotes()
    var actions: LiveRecorderActions?
    let stopAction: () -> Void

    var body: some View {
        // Take exactly the column's space: the split view lays the detail out at its
        // content's ideal height once, and the recorder must never grow past the window.
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Spacer(minLength: 16)
                    stage
                        .frame(maxWidth: BardoLayout.detailContentMaxWidth)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 16)
                    Color.clear.frame(height: BardoLayout.playbackContentClearance)
                }
                .padding(.horizontal, BardoSpacing.detailHorizontal)
                .padding(.top, 20)

                controlBar
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .toolbar {
            LiveRecorderToolbar(title: title, actions: actions, isMicrophoneMuted: isMicrophoneMuted, muteAction: muteAction)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            (Text(isPaused ? "En pausa" : "Grabando")
                .fontWeight(.semibold)
                .foregroundStyle(isPaused ? Color.secondary : Color.red)
             + Text(" · \(subtitle)")
                .foregroundStyle(.secondary))
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    /// The live line with its sources named underneath, stacked and centered.
    private var stage: some View {
        VStack(spacing: 16) {
            LiveConversationWave(tracks: tracks, isPaused: isPaused, notes: notes)
                .frame(minHeight: 120, idealHeight: 200, maxHeight: 220)
            VStack(spacing: 6) {
                ForEach(tracks) { track in
                    sourceName(track)
                }
            }
        }
    }

    /// A source's colour, name and device. The microphone's device opens a menu of the
    /// Mac's inputs, to switch without stopping the recording.
    private func sourceName(_ track: LiveRecorderTrack) -> some View {
        HStack(spacing: 6) {
            Circle().fill(track.tint).frame(width: 7, height: 7)
            Text(track.title)
                .foregroundStyle(.secondary)
            if track.id == "microphone", isMicrophoneMuted {
                Label("Silenciado", systemImage: "mic.slash.fill")
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
            }
            deviceName(track)
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func deviceName(_ track: LiveRecorderTrack) -> some View {
        if let choice = track.choice, !choice.devices.isEmpty {
            Menu {
                Picker("Micrófono", selection: Binding(
                    get: { choice.selectedUID ?? "" },
                    set: { uid in
                        if let device = choice.devices.first(where: { $0.uid == uid }) { choice.select(device) }
                    }
                )) {
                    ForEach(choice.devices) { device in
                        Text(device.menuTitle).tag(device.uid)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    Text(track.detail ?? "Micrófono")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Cambiar de micrófono sin detener la grabación")
        } else if let detail = track.detail {
            Text(detail)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// One large red pause button that carries the running time, and Finalizar on its
    /// own beside it.
    private var controlBar: some View {
        VStack(spacing: 10) {
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LiveRecorderGlassGroup {
                HStack(spacing: 12) {
                    pauseButton
                    Button(action: stopAction) {
                        Label("Finalizar", systemImage: "stop.fill")
                    }
                    .buttonStyle(LiveRecorderButtonStyle(kind: .finish))
                    .help(String(localized: "Stop recording (⌘.)"))
                }
            }
        }
        .padding(.horizontal, BardoLayout.playbackHorizontalPadding)
        .padding(.bottom, BardoLayout.playbackBottomPadding + 4)
    }

    /// As in Voice Memos: red with a white pause symbol and the running time while
    /// recording; "Reanudar" in red on a soft red capsule while paused.
    private var pauseButton: some View {
        Button {
            (isPaused ? resumeAction : pauseAction)?()
        } label: {
            HStack(spacing: 10) {
                if isPaused {
                    Text("Reanudar")
                } else {
                    Image(systemName: "pause.fill")
                }
                LiveRecorderClock(meters: tracks.map(\.meter), isPaused: isPaused)
                    .opacity(isPaused ? 0.75 : 1)
            }
        }
        .buttonStyle(LiveRecorderButtonStyle(kind: isPaused ? .resume : .pause))
        .disabled((isPaused ? resumeAction : pauseAction) == nil)
        .help(isPaused ? String(localized: "Resume recording") : String(localized: "Pause recording"))
        .accessibilityLabel(isPaused ? String(localized: "Resume recording") : String(localized: "Pause recording"))
    }
}

/// The recorder's large capsule buttons.
struct LiveRecorderButtonStyle: ButtonStyle {
    enum Kind {
        /// Solid red with white content.
        case pause
        /// Red content on a soft red capsule.
        case resume
        /// A quiet glass capsule.
        case finish
    }

    let kind: Kind

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.title3.weight(.semibold))
            .padding(.horizontal, kind == .finish ? 22 : 28)
            .frame(height: 52)
            .contentShape(.capsule)

        Group {
            switch kind {
            case .pause:
                // A deep red keeps the white label above 4.5:1; the system red does not.
                label
                    .foregroundStyle(.white)
                    .liveRecorderGlass(tint: BardoColor.stopRecording, fallback: BardoColor.stopRecording)
            case .resume:
                label
                    .foregroundStyle(.red)
                    .liveRecorderGlass(tint: .red.opacity(0.22), fallback: Color.red.opacity(0.16))
            case .finish:
                label
                    .liveRecorderGlass(tint: nil, fallback: .regularMaterial)
            }
        }
        .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    /// Liquid Glass that reacts to the pointer, tinted when `tint` is set; a plain
    /// capsule of `fallback` before macOS 26.
    @ViewBuilder
    func liveRecorderGlass(tint: Color?, fallback: some ShapeStyle) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect((tint.map { Glass.regular.tint($0) } ?? .regular).interactive(), in: .capsule)
        } else {
            background(fallback, in: .capsule)
                .overlay { Capsule().stroke(.separator.opacity(0.3), lineWidth: 0.5) }
        }
    }
}

/// Lets the recorder's glass buttons render and blend as one group on macOS 26.
private struct LiveRecorderGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

/// Keeps the live waveform gliding at the display's pace. Audio arrives in uneven
/// buffers, so the moment shown at the playhead runs with the clock and only leans
/// toward the audio heard, a tenth of a second behind it so each bar is ready when it
/// gets there. The line's colours are blended once per new bar, not on every frame.
@MainActor
final class LiveWaveMotion {
    struct Track {
        var snapshot: LiveAudioMeter.Snapshot
        /// The moment of audio at the playhead, in seconds of the track.
        var time: TimeInterval
    }

    static let latency: TimeInterval = 0.1
    /// How long the audio is assumed to keep flowing after the last buffer.
    static let maximumLead: TimeInterval = 0.25

    private var shown: [ObjectIdentifier: TimeInterval] = [:]
    private var lastFrame: Date?
    private var line: (key: [TimeInterval], first: Int, colors: [Color])?

    /// Each track as of the frame at `date`. It stands still while paused or when
    /// Reduce Motion is on, stepping a bar at a time.
    func frame(
        for tracks: [LiveRecorderTrack],
        at date: Date,
        isMoving: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [Track] {
        let elapsed = min(0.1, max(0, lastFrame.map { date.timeIntervalSince($0) } ?? 0))
        lastFrame = date
        return tracks.map { track in
            let snapshot = track.meter.snapshot
            let id = ObjectIdentifier(track.meter)
            guard isMoving, snapshot.heardAt > 0 else {
                shown[id] = nil
                return Track(snapshot: snapshot, time: snapshot.newestBarEnd)
            }
            let target = snapshot.duration - Self.latency + min(Self.maximumLead, max(0, now - snapshot.heardAt))
            // Starts from the newest bar, so resuming never jumps ahead.
            var time = shown[id].map { $0 + elapsed } ?? min(target, snapshot.newestBarEnd)
            let error = target - time
            time = abs(error) > 0.5 ? target : time + error * min(1, elapsed * 3)
            shown[id] = time
            return Track(snapshot: snapshot, time: time)
        }
    }

    /// The blended colour under each of the first track's newest `count` bars, and the
    /// index of the first of them.
    func lineColors(
        for tracks: [LiveRecorderTrack],
        frame: [Track],
        count: Int,
        in environment: EnvironmentValues
    ) -> (first: Int, colors: [Color]) {
        let key = frame.flatMap { [$0.snapshot.newestBarEnd, Double($0.snapshot.levels.count)] } + [Double(count)]
        if let line, line.key == key { return (line.first, line.colors) }
        let upper = frame[0].snapshot.levels
        let lower = frame.count > 1 ? frame[1].snapshot.levels : nil
        let first = max(0, upper.count - count)
        let samples = upper.indices.suffix(from: first).map { index in
            let age = upper.count - 1 - index
            return ConversationWaveformStyle.VoiceSample(
                x: 0,
                upper: CGFloat(upper[index]),
                lower: lower.map { $0.count - 1 - age >= 0 ? CGFloat($0[$0.count - 1 - age]) : 0 }
            )
        }
        let colors = ConversationWaveformStyle.blendedColors(
            of: samples,
            upperTint: tracks[0].tint,
            lowerTint: tracks.count > 1 ? tracks[1].tint : tracks[0].tint,
            singleTint: tracks[0].tint,
            in: environment
        )
        line = (key, first, colors)
        return (first, colors)
    }
}

/// The Mac's audio rises above one shared line and your voice falls below it, so the
/// turns of a call read at a glance; a single source fills both sides. Audio enters at a
/// red playhead on the right and drifts left, fading as it ages. The meters are read on
/// every frame, at the display's full rate, so the levels never re-render anything else.
struct LiveConversationWave: View {
    let tracks: [LiveRecorderTrack]
    let isPaused: Bool
    var notes = RecordingNotes()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = LiveWaveMotion()

    private let barWidth: CGFloat = 2
    private let step: CGFloat = 4
    /// Room on the right for the playhead and its dots.
    private let playheadInset: CGFloat = 10
    /// Space kept clear on each side of the line, so the halves never touch.
    private let gap: CGFloat = 3

    var body: some View {
        // Under Reduce Motion the bars step once per bar, so there is nothing to glide.
        TimelineView(.animation(minimumInterval: reduceMotion ? LiveAudioMeter.bucketDuration : nil, paused: isPaused)) { timeline in
            Canvas { canvas, size in
                guard !tracks.isEmpty else { return }
                let frame = motion.frame(for: tracks, at: timeline.date, isMoving: !isPaused && !reduceMotion)
                var bars = canvas
                // Older audio fades out toward the leading edge instead of being cut off.
                bars.clipToLayer { layer in
                    layer.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .linearGradient(
                            Gradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: size.width, y: 0)
                        )
                    )
                }
                if isPaused { bars.opacity = 0.5 }
                drawVoiceLine(in: &bars, size: size, frame: frame)
                if tracks.count == 1 {
                    draw(frame[0], tint: tracks[0].tint, in: &bars, size: size, direction: 0)
                } else {
                    for index in 0..<min(2, tracks.count) {
                        draw(frame[index], tint: tracks[index].tint, in: &bars, size: size, direction: index == 0 ? -1 : 1)
                    }
                }
                drawNotes(in: &canvas, size: size, frame: frame)
                drawPlayhead(in: &canvas, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    /// Where the newest bar is drawn the moment it arrives.
    private func newest(in size: CGSize) -> CGFloat {
        size.width - playheadInset - barWidth - 3
    }

    /// Where the bar ending at `end` sits while `time` is at the playhead.
    private func x(ending end: TimeInterval, at time: TimeInterval, size: CGSize) -> CGFloat {
        newest(in: size) - CGFloat((time - end) / LiveAudioMeter.bucketDuration) * step
    }

    /// Calls `body` with each bar on screen, newest first, once the playhead reaches it.
    private func forEachVisibleBar(of track: LiveWaveMotion.Track, size: CGSize, _ body: (_ index: Int, _ x: CGFloat) -> Void) {
        let snapshot = track.snapshot
        for index in snapshot.levels.indices.reversed() {
            let end = snapshot.newestBarEnd - Double(snapshot.levels.count - 1 - index) * LiveAudioMeter.bucketDuration
            guard end <= track.time + 0.001 else { continue }
            let x = x(ending: end, at: track.time, size: size)
            guard x > -barWidth else { break }
            body(index, x)
        }
    }

    /// `direction` -1 draws above the line, 1 below it and 0 on both sides.
    private func draw(_ track: LiveWaveMotion.Track, tint: Color, in context: inout GraphicsContext, size: CGSize, direction: CGFloat) {
        let middle = size.height / 2
        // Each half draws only in its own band: the Mac's audio can never cross below
        // the line, nor your voice above it.
        var canvas = context
        switch direction {
        case ..<0: canvas.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: middle - gap)))
        case 0: break
        default: canvas.clip(to: Path(CGRect(x: 0, y: middle + gap, width: size.width, height: middle - gap)))
        }
        let reach = middle - gap - 6
        let corner = CGSize(width: barWidth / 2, height: barWidth / 2)
        // Every bar goes into one shape, filled once.
        var shape = Path()
        forEachVisibleBar(of: track, size: size) { index, x in
            let height = pow(CGFloat(track.snapshot.levels[index]), 2) * reach
            // Room noise leaves the line clean instead of dotting it.
            guard height > 2 else { return }
            // A single source mirrors on both sides; nothing ever crosses the line.
            if direction <= 0 {
                shape.addRoundedRect(in: CGRect(x: x, y: middle - gap - height, width: barWidth, height: height), cornerSize: corner)
            }
            if direction >= 0 {
                shape.addRoundedRect(in: CGRect(x: x, y: middle + gap, width: barWidth, height: height), cornerSize: corner)
            }
        }
        canvas.fill(shape, with: .color(tint))
    }

    /// The line between the halves, coloured by whoever is heard as it drifts left.
    private func drawVoiceLine(in canvas: inout GraphicsContext, size: CGSize, frame: [LiveWaveMotion.Track]) {
        let lineSize = CGSize(width: size.width - playheadInset, height: size.height)
        // Enough bars to cross the view, and a few past its edge so the blend is the same there.
        let line = motion.lineColors(for: tracks, frame: frame, count: Int(size.width / step) + 24, in: canvas.environment)
        let upper = frame[0].snapshot.levels
        let lower = frame.count > 1 ? frame[1].snapshot.levels : nil
        var samples: [ConversationWaveformStyle.VoiceSample] = []
        var sampleColors: [Color] = []
        forEachVisibleBar(of: frame[0], size: size) { index, x in
            guard x + barWidth / 2 > 0, index >= line.first else { return }
            let age = upper.count - 1 - index
            samples.append(.init(
                x: x + barWidth / 2,
                upper: CGFloat(upper[index]),
                lower: lower.map { $0.count - 1 - age >= 0 ? CGFloat($0[$0.count - 1 - age]) : 0 }
            ))
            sampleColors.append(line.colors[index - line.first])
        }
        // Before there is enough audio to reach the leading edge, the line still does.
        if let oldest = samples.last, let color = sampleColors.last, oldest.x > step {
            samples.append(.init(x: oldest.x.truncatingRemainder(dividingBy: step), upper: 0, lower: lower == nil ? nil : 0))
            sampleColors.append(color)
        }
        // The line runs left to right.
        ConversationWaveformStyle.drawVoiceLine(
            in: &canvas,
            size: lineSize,
            samples: samples.reversed(),
            colors: sampleColors.reversed()
        )
    }

    /// Sections and moments drawn as on a saved recording, drifting left with the audio.
    private func drawNotes(in canvas: inout GraphicsContext, size: CGSize, frame: [LiveWaveMotion.Track]) {
        guard !notes.isEmpty, let latest = frame.max(by: { $0.snapshot.duration < $1.snapshot.duration }) else { return }
        func x(for time: TimeInterval) -> CGFloat {
            self.x(ending: time, at: latest.time, size: size)
        }
        let sections = notes.sections.sorted { $0.start < $1.start }
        for (index, section) in sections.enumerated() {
            let position = x(for: section.start)
            guard position > 0, position < size.width else { continue }
            let next = index + 1 < sections.count ? x(for: sections[index + 1].start) : size.width - playheadInset
            ConversationWaveformStyle.drawSection(
                in: &canvas,
                x: position,
                size: size,
                title: section.title,
                maxWidth: next - position - 14
            )
        }
        for moment in notes.moments {
            let position = x(for: moment.time)
            guard position > 0, position < size.width else { continue }
            ConversationWaveformStyle.drawMoment(in: &canvas, x: position, size: size)
        }
    }

    /// Where audio enters: red while recording, grey while paused.
    private func drawPlayhead(in canvas: inout GraphicsContext, size: CGSize) {
        ConversationWaveformStyle.drawPlayhead(
            in: &canvas,
            x: size.width - playheadInset / 2,
            size: size,
            color: isPaused ? .secondary : .red
        )
    }
}

/// The running time, with hundredths like Voice Memos, from the audio actually heard.
/// It takes the font and colour of the button it sits in.
struct LiveRecorderClock: View {
    let meters: [LiveAudioMeter]
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { _ in
            let duration = meters.map(\.snapshot.duration).max() ?? 0
            Text(LiveRecorderClock.format(duration))
                .monospacedDigit()
                .contentTransition(.identity)
                .accessibilityLabel(Text(LibraryFormatting.duration(duration)))
        }
    }

    /// `05:42,17`, or `1:05:42,17` past an hour, with the locale's decimal separator.
    static func format(_ duration: TimeInterval, locale: Locale = .current) -> String {
        let hundredths = Int((max(0, duration) * 100).rounded(.down))
        let seconds = hundredths / 100
        let fraction = String(format: "%02d", hundredths % 100)
        let separator = locale.decimalSeparator ?? ","
        let clock = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return clock + separator + fraction
    }
}

