import Foundation

struct SpeakerPreview: Equatable, Sendable {
    let speakerID: Speaker.ID
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum SpeakerPreviewSelector {
    private struct AudioInterval {
        let start: TimeInterval
        let end: TimeInterval

        var duration: TimeInterval {
            end - start
        }
    }

    static func previews(
        for transcript: Transcript,
        maxDuration: TimeInterval = 10
    ) -> [SpeakerPreview] {
        let durationLimit = min(maxDuration, 10)
        guard durationLimit > 0, durationLimit.isFinite else { return [] }

        return transcript.speakers.compactMap { speaker in
            guard let interval = longestContinuousInterval(
                for: speaker.id,
                in: transcript
            ) else {
                return nil
            }

            return SpeakerPreview(
                speakerID: speaker.id,
                startTime: interval.start,
                endTime: min(interval.end, interval.start + durationLimit)
            )
        }
    }

    private static func longestContinuousInterval(
        for speakerID: Speaker.ID,
        in transcript: Transcript
    ) -> AudioInterval? {
        let intervals = transcript.segments
            .filter { $0.speakerID == speakerID }
            .compactMap { segment -> AudioInterval? in
                guard segment.startTime.isFinite,
                      segment.endTime.isFinite,
                      segment.startTime >= 0,
                      segment.endTime > segment.startTime else {
                    return nil
                }
                let wordIntervals = segment.words.compactMap { word -> AudioInterval? in
                    guard word.startTime.isFinite,
                          word.endTime.isFinite,
                          word.startTime >= segment.startTime,
                          word.endTime <= segment.endTime,
                          word.endTime > word.startTime else {
                        return nil
                    }
                    return AudioInterval(start: word.startTime, end: word.endTime)
                }

                guard let firstWord = wordIntervals.min(by: { $0.start < $1.start }),
                      let lastWord = wordIntervals.max(by: { $0.end < $1.end }) else {
                    return AudioInterval(start: segment.startTime, end: segment.endTime)
                }

                return AudioInterval(start: firstWord.start, end: lastWord.end)
            }
            .sorted {
                if $0.start == $1.start {
                    return $0.end < $1.end
                }
                return $0.start < $1.start
            }

        guard var current = intervals.first else { return nil }
        var longest = current

        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current = AudioInterval(
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                if current.duration > longest.duration {
                    longest = current
                }
                current = interval
            }
        }

        if current.duration > longest.duration {
            longest = current
        }
        return longest
    }
}
