import SwiftUI

// Motion for long-running transcription, adapted from transitions.dev:
// "Thinking states" (a status line that shimmers while it holds and swaps with a
// short rise and blur) and "Streaming text" (text that resolves through opacity
// and a small blur). Both rest completely still when Reduce Motion is on.

/// Motion tokens shared by the status line and the live transcript.
enum TranscriptionMotion {
    /// One shimmer sweep across the status line.
    static let shimmerPeriod: TimeInterval = 2
    /// Status swap: the outgoing line leaves, the incoming one waits a beat and enters.
    static let swap = Animation.easeInOut(duration: 0.15)
    static let swapGap: TimeInterval = 0.05
    static let swapDistance: CGFloat = 8
    static let swapBlur: CGFloat = 2
    /// "Streaming text": each word of a new passage resolves one gap after the
    /// previous one, over the fade, along cubic-bezier(0.22, 1, 0.36, 1).
    static let streamWordGap: TimeInterval = 0.06
    static let streamFade: TimeInterval = 0.35
    static let streamCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.22, y: 1),
        endControlPoint: UnitPoint(x: 0.36, y: 1)
    )
    /// A long passage speeds up so it never takes longer than this to appear.
    static let streamMaximumReveal: TimeInterval = 1.5
}

/// A status line that shimmers while work is under way and swaps with a short rise
/// and blur whenever the status really changes.
struct ThinkingText: View {
    let text: String
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            line
                .id(text)
                .transition(reduceMotion ? .identity : .thinkingSwap)
        }
        .animation(reduceMotion ? nil : TranscriptionMotion.swap, value: text)
    }

    @ViewBuilder
    private var line: some View {
        if isActive && !reduceMotion {
            Text(text)
                .foregroundStyle(.secondary)
                .overlay {
                    ShimmerSweep()
                        .mask(Text(text))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            Text(text)
        }
    }
}

/// A soft highlight that travels left to right across its frame once per period.
private struct ShimmerSweep: View {
    var body: some View {
        // 30 fps is plenty for a slow sweep and keeps the cost negligible.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let period = TranscriptionMotion.shimmerPeriod
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            GeometryReader { proxy in
                let band = max(proxy.size.width * 0.35, 36)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .primary, location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + (proxy.size.width + band) * phase)
            }
        }
    }
}

private struct RiseBlur: ViewModifier {
    let opacity: Double
    let offset: CGFloat
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: offset)
            .blur(radius: blur)
    }
}

extension AnyTransition {
    /// "Thinking states": the outgoing line rises out as the incoming one rises in.
    static var thinkingSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: RiseBlur(opacity: 0, offset: TranscriptionMotion.swapDistance, blur: TranscriptionMotion.swapBlur),
                identity: RiseBlur(opacity: 1, offset: 0, blur: 0)
            )
            .animation(TranscriptionMotion.swap.delay(TranscriptionMotion.swapGap)),
            removal: .modifier(
                active: RiseBlur(opacity: 0, offset: -TranscriptionMotion.swapDistance, blur: TranscriptionMotion.swapBlur),
                identity: RiseBlur(opacity: 1, offset: 0, blur: 0)
            )
        )
    }

}

/// "Streaming text" for a passage Whisper has just recognised: its words appear in
/// order, each fading in one gap after the previous one. The reveal happens inside a
/// single `Text` (only the words' opacity changes, so nothing reflows), runs once, and
/// then the passage is ordinary text again. Settled text is never animated.
struct StreamingRevealText: View {
    let text: String
    /// When this passage arrived; `nil` for text that was already on screen.
    let revealStart: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFinished = false

    var body: some View {
        if let revealStart, !isFinished, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                Text(Self.revealed(text, elapsed: context.date.timeIntervalSince(revealStart)))
            }
            .task(id: revealStart) {
                let remaining = revealStart.addingTimeInterval(Self.duration(for: text)).timeIntervalSinceNow
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                }
                isFinished = true
            }
        } else {
            Text(text)
        }
    }

    static func wordGap(wordCount: Int) -> TimeInterval {
        let budget = TranscriptionMotion.streamMaximumReveal - TranscriptionMotion.streamFade
        return min(TranscriptionMotion.streamWordGap, budget / Double(max(wordCount - 1, 1)))
    }

    static func duration(for text: String) -> TimeInterval {
        let count = words(in: text).count
        return Double(max(count - 1, 0)) * wordGap(wordCount: count) + TranscriptionMotion.streamFade
    }

    static func revealed(_ text: String, elapsed: TimeInterval) -> AttributedString {
        let words = words(in: text)
        let gap = wordGap(wordCount: words.count)
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var part = AttributedString(index < words.count - 1 ? word + " " : word)
            let progress = min(1, max(0, (elapsed - Double(index) * gap) / TranscriptionMotion.streamFade))
            part.foregroundColor = Color.primary.opacity(TranscriptionMotion.streamCurve.value(at: progress))
            result.append(part)
        }
        return result
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
