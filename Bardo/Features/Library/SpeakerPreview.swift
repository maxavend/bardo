import Foundation

struct SpeakerPreviewClip: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }
}

enum SpeakerPreviewClipSelector {
    private static let maximumJoinGap: TimeInterval = 1

    static func clip(
        for speakerID: Speaker.ID,
        in segments: [TranscriptSegment],
        maximumDuration: TimeInterval = 10
    ) -> SpeakerPreviewClip? {
        guard maximumDuration.isFinite, maximumDuration > 0 else { return nil }

        let ordered = segments
            .filter {
                $0.startTime.isFinite
                    && $0.endTime.isFinite
                    && $0.endTime > $0.startTime
            }
            .sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }

        var best: SpeakerPreviewClip?
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?

        func commitCurrentRun() {
            guard let start = currentStart, let end = currentEnd, end > start else { return }
            let candidate = SpeakerPreviewClip(startTime: start, endTime: end)
            if best == nil || candidate.duration > best!.duration {
                best = candidate
            }
        }

        for segment in ordered {
            guard segment.speakerID == speakerID else {
                commitCurrentRun()
                currentStart = nil
                currentEnd = nil
                continue
            }

            if let end = currentEnd,
               segment.startTime - end <= maximumJoinGap {
                currentEnd = max(end, segment.endTime)
            } else {
                commitCurrentRun()
                currentStart = segment.startTime
                currentEnd = segment.endTime
            }
        }

        commitCurrentRun()

        guard let best else { return nil }
        return SpeakerPreviewClip(
            startTime: best.startTime,
            endTime: min(best.endTime, best.startTime + maximumDuration)
        )
    }
}
