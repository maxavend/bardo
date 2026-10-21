import SwiftUI

/// How Bardo draws every conversation, live or saved: your voice rises above one shared
/// line in blue and the Mac's audio falls below it in orange; a single track fills both
/// sides. Moments are an orange hairline with a dot on top, sections a quiet hairline,
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

/// A saved recording from start to end, drawn like the recorder: what has been heard in
/// full colour and what is ahead dimmed, with its moments and sections. Click or drag to
/// jump.
struct RecordingWaveform: View {
    let recording: Recording
    @ObservedObject var playback: AudioPlaybackController
    var matches: [TimeInterval] = []
    /// Draws section names along the top; the full player has its own lane for them.
    var labelsSections = true

    @StateObject private var overview = AudioWaveformOverviewModel()

    private var duration: TimeInterval {
        playback.duration > 0 ? playback.duration : (recording.duration ?? 0)
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { canvas, size in
                draw(in: &canvas, size: size)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard duration > 0 else { return }
                    let span = max(1, proxy.size.width - Self.inset * 2)
                    playback.seek(to: Double(min(1, max(0, (value.location.x - Self.inset) / span))) * duration)
                }
            )
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

    /// Leaves room at both ends for the playhead's and the moments' dots.
    static let inset = ConversationWaveformStyle.dotSize / 2

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return Self.inset }
        return Self.inset + CGFloat(min(1, max(0, time / duration))) * (width - Self.inset * 2)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize) {
        typealias Style = ConversationWaveformStyle
        Style.drawCenterLine(in: &canvas, size: size)

        let playhead = x(for: playback.position, width: size.width)
        let span = size.width - Self.inset * 2
        let count = max(1, Int(span / Style.step))
        if let lanes = overview.lanes?.normalized {
            for bar in 0..<count {
                let x = Self.inset + CGFloat(bar) * Style.step
                // What has been heard reads in full colour; what is ahead, dimmed.
                let opacity = playback.position > 0 && x > playhead ? 0.35 : 1
                if let lower = lanes.lower {
                    Style.drawBar(in: &canvas, x: x, level: level(lanes.upper, bar, count), direction: -1, size: size, color: Style.microphoneTint.opacity(opacity))
                    Style.drawBar(in: &canvas, x: x, level: level(lower, bar, count), direction: 1, size: size, color: Style.systemTint.opacity(opacity))
                } else {
                    Style.drawBar(in: &canvas, x: x, level: level(lanes.upper, bar, count), direction: 0, size: size, color: recording.waveformTint.opacity(opacity))
                }
            }
        }

        for section in recording.notes.sections {
            Style.drawSection(in: &canvas, x: x(for: section.start, width: size.width), size: size, title: labelsSections ? section.title : nil)
        }
        for moment in recording.notes.moments {
            Style.drawMoment(in: &canvas, x: x(for: moment.time, width: size.width), size: size)
        }
        for match in matches {
            let x = x(for: match, width: size.width)
            canvas.fill(
                Path(roundedRect: CGRect(x: x - 2, y: size.height - 4, width: 4, height: 4), cornerRadius: 2),
                with: .color(.yellow)
            )
        }
        if duration > 0 {
            Style.drawPlayhead(in: &canvas, x: playhead, size: size, color: .primary)
        }
    }

    /// The loudest of the levels a bar covers.
    private func level(_ levels: [Float], _ bar: Int, _ count: Int) -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        let first = bar * levels.count / count
        let last = max(first + 1, (bar + 1) * levels.count / count)
        return CGFloat(levels[first..<min(last, levels.count)].max() ?? 0)
    }
}
