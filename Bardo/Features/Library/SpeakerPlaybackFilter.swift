import Foundation

/// Lets playback hear only some of the participants: what the others say, and the pauses
/// around it, are skipped. A little air is kept around each turn, and short gaps between
/// kept turns play through, so speech never sounds clipped or jumpy.
enum SpeakerPlaybackFilter {
    static let padding: TimeInterval = 0.25
    /// Gaps between kept turns shorter than this play through instead of being jumped.
    static let shortestSkip: TimeInterval = 1

    /// The stretches of a recording `duration` long where none of `speakers` is talking.
    static func skippedRanges(
        of transcript: Transcript,
        keeping speakers: Set<Speaker.ID>,
        duration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        guard duration > 0 else { return [] }
        let turns = transcript.segments
            .filter { $0.speakerID.map(speakers.contains) ?? false }
            .map { max(0, $0.startTime - padding)...min(duration, max(0, $0.endTime + padding)) }
        var skipped: [ClosedRange<TimeInterval>] = []
        var heardUntil: TimeInterval = 0
        for turn in merged(turns) {
            if turn.lowerBound - heardUntil >= shortestSkip {
                skipped.append(heardUntil...turn.lowerBound)
            }
            heardUntil = max(heardUntil, turn.upperBound)
        }
        if duration - heardUntil >= shortestSkip {
            skipped.append(heardUntil...duration)
        }
        return skipped
    }

    /// The ranges in order, with overlapping or touching ones joined.
    static func merged(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        var result: [ClosedRange<TimeInterval>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
