import SwiftUI

/// One source of the recording in progress, drawn as its own waveform lane.
struct LiveRecorderTrack: Identifiable {
    let id: String
    let title: LocalizedStringKey
    /// The device it comes from, when Bardo knows it.
    let detail: String?
    let systemImage: String
    let tint: Color
    let meter: LiveAudioMeter

    static func microphone(_ meter: LiveAudioMeter, device: String?) -> LiveRecorderTrack {
        LiveRecorderTrack(id: "microphone", title: "Tu micrófono", detail: device, systemImage: "mic", tint: .blue, meter: meter)
    }

    static func system(_ meter: LiveAudioMeter) -> LiveRecorderTrack {
        LiveRecorderTrack(id: "system", title: "Audio del Mac", detail: nil, systemImage: "macbook", tint: .orange, meter: meter)
    }
}

/// The detail column while Bardo records: what is being recorded, a live waveform for
/// each source, the running time and the controls to pause or finish.
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
            content
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, BardoSpacing.section)

            Spacer(minLength: 12)

            VStack(spacing: 16) {
                ForEach(tracks) { track in
                    LiveRecorderLane(track: track, isPaused: isPaused)
                }
            }
            .frame(maxWidth: BardoLayout.detailContentMaxWidth)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 12)

            VStack(spacing: 14) {
                LiveRecorderClock(meters: tracks.map(\.meter), isPaused: isPaused)

                HStack(spacing: 12) {
                    if let pauseAction, !isPaused {
                        Button(action: pauseAction) {
                            Label(String(localized: "Pause"), systemImage: "pause.fill")
                        }
                        .help(String(localized: "Pause recording"))
                    }
                    if let resumeAction, isPaused {
                        Button(action: resumeAction) {
                            Label(String(localized: "Resume"), systemImage: "play.fill")
                        }
                        .help(String(localized: "Resume recording"))
                    }
                    // A deep red keeps the white label above 4.5:1; the system red does not.
                    Button(action: stopAction) {
                        Label("Finalizar", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BardoColor.stopRecording)
                    .help(String(localized: "Stop recording (⌘.)"))
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)

                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, BardoSpacing.detailHorizontal)
        .padding(.top, 20)
        .padding(.bottom, 28)
    }
}

/// A source's name above its live waveform.
private struct LiveRecorderLane: View {
    let track: LiveRecorderTrack
    let isPaused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(track.title, systemImage: track.systemImage)
                    .font(.callout.weight(.semibold))
                if let detail = track.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            LiveWaveform(meter: track.meter, tint: track.tint, isPaused: isPaused)
                .frame(minHeight: 48, idealHeight: 112, maxHeight: 140)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(track.title))
        .accessibilityValue(track.detail.map { Text($0) } ?? Text(""))
    }
}

/// Bars of recent loudness that scroll from right to left as audio arrives. It reads its
/// meter on every frame, so the levels never re-render anything else.
struct LiveWaveform: View {
    let meter: LiveAudioMeter
    let tint: Color
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barWidth: CGFloat = 3
    private static let step: CGFloat = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isPaused)) { context in
            Canvas { canvas, size in
                draw(meter.snapshot, at: context.date, in: &canvas, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ snapshot: LiveAudioMeter.Snapshot, at date: Date, in canvas: inout GraphicsContext, size: CGSize) {
        guard size.width > Self.step, size.height > 4 else { return }
        // Glide the newest bar left until the next one arrives, unless motion is reduced.
        var glide: CGFloat = 0
        if !reduceMotion, !isPaused, snapshot.lastBarTime > 0 {
            let elapsed = ProcessInfo.processInfo.systemUptime - snapshot.lastBarTime
            glide = CGFloat(min(1, max(0, elapsed / LiveAudioMeter.bucketDuration)))
        }

        let middle = size.height / 2
        let maximum = size.height - 8
        let count = Int(size.width / Self.step) + 2
        let levels = snapshot.levels
        for slot in 0..<count {
            let x = size.width - Self.barWidth - (CGFloat(slot) + glide) * Self.step
            guard x > -Self.barWidth else { break }
            let index = levels.count - 1 - slot
            // Silence, and the time before the recording started, is a dotted line.
            let level = index >= 0 ? CGFloat(levels[index]) : 0
            let height = max(Self.barWidth, pow(level, 1.6) * maximum)
            let rect = CGRect(x: x, y: middle - height / 2, width: Self.barWidth, height: height)
            // Older audio fades toward the left edge.
            let age = max(0, min(1, x / size.width))
            let opacity = index >= 0 ? 0.3 + 0.7 * age : 0.25
            canvas.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(tint.opacity(opacity)))
        }
    }
}

/// The running time, with hundredths like Voice Memos, from the audio actually heard.
struct LiveRecorderClock: View {
    let meters: [LiveAudioMeter]
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { _ in
            let duration = meters.map(\.snapshot.duration).max() ?? 0
            HStack(spacing: 8) {
                Image(systemName: isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .symbolEffect(.pulse, isActive: !isPaused)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(LiveRecorderClock.format(duration))
                    .font(.system(size: 40, weight: .light).monospacedDigit())
                    .contentTransition(.identity)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isPaused ? Text("Grabación en pausa") : Text("Grabando"))
            .accessibilityValue(Text(LibraryFormatting.duration(duration)))
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
