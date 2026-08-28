import Foundation

struct CapturePauseDecision: Equatable, Sendable {
    let shouldAppend: Bool
    let timestampOffset: TimeInterval
}

/// Maps a source clock that continues while recording is paused onto a contiguous output
/// timeline. Paused samples are discarded and the wall-clock gap is subtracted from every
/// subsequent sample. The state is deliberately small and deterministic so pause/resume
/// behavior can be regression-tested independently of ScreenCaptureKit.
struct CapturePauseTimeline: Equatable, Sendable {
    private(set) var isPaused = false
    private(set) var accumulatedPause: TimeInterval = 0
    private var firstPausedTimestamp: TimeInterval?
    private var resumePending = false

    mutating func pause() {
        guard !isPaused else { return }
        isPaused = true
        firstPausedTimestamp = nil
        resumePending = false
    }

    mutating func resume() {
        guard isPaused else { return }
        isPaused = false
        resumePending = true
    }

    mutating func decision(for sourceTimestamp: TimeInterval) -> CapturePauseDecision {
        guard sourceTimestamp.isFinite else {
            return CapturePauseDecision(
                shouldAppend: !isPaused,
                timestampOffset: accumulatedPause
            )
        }

        if isPaused {
            if firstPausedTimestamp == nil {
                firstPausedTimestamp = sourceTimestamp
            }
            return CapturePauseDecision(
                shouldAppend: false,
                timestampOffset: accumulatedPause
            )
        }

        if resumePending {
            if let firstPausedTimestamp {
                accumulatedPause += max(0, sourceTimestamp - firstPausedTimestamp)
            }
            firstPausedTimestamp = nil
            resumePending = false
        }

        return CapturePauseDecision(
            shouldAppend: true,
            timestampOffset: accumulatedPause
        )
    }
}
