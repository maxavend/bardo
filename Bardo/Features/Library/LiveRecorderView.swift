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

    /// Your voice, above the line, in the transcript's colour for you.
    static func microphone(_ meter: LiveAudioMeter, device: String?, choice: LiveMicrophoneChoice? = nil) -> LiveRecorderTrack {
        LiveRecorderTrack(id: "microphone", title: "Tu micrófono", detail: device, tint: .blue, meter: meter, choice: choice)
    }

    /// The Mac's audio, below the line, in the colour of the first other speaker.
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
            LiveConversationWave(tracks: tracks, isPaused: isPaused)
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
            HStack(spacing: 12) {
                pauseButton
                Button(action: stopAction) {
                    Label("Finalizar", systemImage: "stop.fill")
                }
                .buttonStyle(LiveRecorderButtonStyle(kind: .finish))
                .help(String(localized: "Stop recording (⌘.)"))
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
                    .background(BardoColor.stopRecording, in: .capsule)
            case .resume:
                label
                    .foregroundStyle(.red)
                    .background(Color.red.opacity(0.16), in: .capsule)
            case .finish:
                label
                    .bardoGlassCapsule()
            }
        }
        .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension LiveAudioMeter.Snapshot {
    /// How far the newest bar has glided left toward the next one, from 0 to 1. It stays
    /// still while paused or when Reduce Motion is on.
    func glide(isPaused: Bool, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, !isPaused, lastBarTime > 0 else { return 0 }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastBarTime
        return CGFloat(min(1, max(0, elapsed / LiveAudioMeter.bucketDuration)))
    }
}

/// Your voice rises above one shared line and the Mac's audio falls below it, so the
/// turns of a call read at a glance; a single source fills both sides. Audio enters at a
/// red playhead on the right and drifts left, fading as it ages. The meters are read on
/// every frame, so the levels never re-render anything else.
struct LiveConversationWave: View {
    let tracks: [LiveRecorderTrack]
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWidth: CGFloat = 2
    private let step: CGFloat = 4
    /// Room on the right for the playhead and its dots.
    private let playheadInset: CGFloat = 10
    /// Space kept clear on each side of the line, so the halves never touch.
    private let gap: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isPaused)) { _ in
            Canvas { canvas, size in
                let middle = size.height / 2
                canvas.fill(
                    Path(CGRect(x: 0, y: middle - 0.25, width: size.width - playheadInset, height: 0.5)),
                    with: .color(.secondary.opacity(0.35))
                )
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
                if tracks.count == 1, let track = tracks.first {
                    draw(track, in: &bars, size: size, direction: 0)
                } else {
                    for (offset, track) in tracks.prefix(2).enumerated() {
                        draw(track, in: &bars, size: size, direction: offset == 0 ? -1 : 1)
                    }
                }
                drawPlayhead(in: &canvas, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    /// `direction` -1 draws above the line, 1 below it and 0 on both sides.
    private func draw(_ track: LiveRecorderTrack, in context: inout GraphicsContext, size: CGSize, direction: CGFloat) {
        let snapshot = track.meter.snapshot
        let glide = snapshot.glide(isPaused: isPaused, reduceMotion: reduceMotion)
        let middle = size.height / 2
        // Each half draws only in its own band: your voice can never cross below the
        // line, nor the Mac's audio above it.
        var canvas = context
        switch direction {
        case ..<0: canvas.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: middle - gap)))
        case 0: break
        default: canvas.clip(to: Path(CGRect(x: 0, y: middle + gap, width: size.width, height: middle - gap)))
        }
        let reach = (direction == 0 ? middle : middle - gap) - 6
        let levels = snapshot.levels
        let newest = size.width - playheadInset - barWidth - 3
        let count = Int(newest / step) + 2
        for slot in 0..<count {
            let x = newest - (CGFloat(slot) + glide) * step
            guard x > -barWidth else { break }
            let index = levels.count - 1 - slot
            guard index >= 0 else { break }
            let height = pow(CGFloat(levels[index]), 2) * reach
            // Room noise leaves the line clean instead of dotting it.
            guard height > 2 else { continue }
            let rect: CGRect
            switch direction {
            case ..<0: rect = CGRect(x: x, y: middle - gap - height, width: barWidth, height: height)
            case 0: rect = CGRect(x: x, y: middle - height, width: barWidth, height: height * 2)
            default: rect = CGRect(x: x, y: middle + gap, width: barWidth, height: height)
            }
            canvas.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(track.tint))
        }
    }

    /// Where audio enters: a red line with a dot at each end, grey while paused.
    private func drawPlayhead(in canvas: inout GraphicsContext, size: CGSize) {
        let x = size.width - playheadInset / 2
        let color: Color = isPaused ? .secondary : .red
        let dot: CGFloat = 6
        canvas.fill(Path(CGRect(x: x - 0.75, y: dot / 2, width: 1.5, height: size.height - dot)), with: .color(color))
        canvas.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: 0, width: dot, height: dot)), with: .color(color))
        canvas.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: size.height - dot, width: dot, height: dot)), with: .color(color))
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
