import Foundation

struct TranscriptReadingBlock: Identifiable, Equatable, Sendable {
    let id: TranscriptSegment.ID
    let speakerID: Speaker.ID?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let segments: [TranscriptSegment]
    let text: String

    var hasManualEdits: Bool {
        segments.contains { $0.editedText != nil }
    }
}

enum TranscriptReadingBlockBuilder {
    static let defaultPauseBreak: TimeInterval = 5

    static func blocks(
        from segments: [TranscriptSegment],
        pauseBreak: TimeInterval = defaultPauseBreak
    ) -> [TranscriptReadingBlock] {
        guard pauseBreak.isFinite, pauseBreak >= 0 else { return [] }

        let ordered = segments
            .filter { !$0.displayText.isEmpty }
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.startTime < $1.startTime
            }

        guard let first = ordered.first else { return [] }

        var result: [TranscriptReadingBlock] = []
        var currentSegments = [first]
        var currentSpeakerID = first.speakerID
        var previous = first

        for segment in ordered.dropFirst() {
            let gap = max(0, segment.startTime - previous.endTime)
            let startsNewBlock = segment.speakerID != currentSpeakerID || gap >= pauseBreak

            if startsNewBlock {
                result.append(makeBlock(from: currentSegments))
                currentSegments = [segment]
                currentSpeakerID = segment.speakerID
            } else {
                currentSegments.append(segment)
            }

            previous = segment
        }

        result.append(makeBlock(from: currentSegments))
        return result
    }

    private static func makeBlock(from segments: [TranscriptSegment]) -> TranscriptReadingBlock {
        let first = segments[0]
        let endTime = segments.reduce(first.endTime) { max($0, $1.endTime) }
        let text = TranscriptTextSanitizer.sanitize(
            segments.map(\.displayText).joined(separator: " ")
        )

        return TranscriptReadingBlock(
            id: first.id,
            speakerID: first.speakerID,
            startTime: first.startTime,
            endTime: endTime,
            segments: segments,
            text: text
        )
    }
}

enum TranscriptPlaybackMapping {
    /// Keeps the reading UI coupled to speech, not to the player's 10 Hz timer. A block is
    /// active while its spoken range is playing, with a tiny tail so the highlight does not
    /// flicker on timestamp rounding. Long silence intentionally has no active block.
    static func activeBlockID(
        at position: TimeInterval,
        in blocks: [TranscriptReadingBlock],
        tailTolerance: TimeInterval = 0.35
    ) -> TranscriptReadingBlock.ID? {
        guard position.isFinite,
              position >= 0,
              tailTolerance.isFinite,
              tailTolerance >= 0,
              !blocks.isEmpty else {
            return nil
        }

        var lowerBound = 0
        var upperBound = blocks.count - 1
        var candidateIndex: Int?

        while lowerBound <= upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if blocks[middle].startTime <= position {
                candidateIndex = middle
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }

        guard let candidateIndex else { return nil }
        let candidate = blocks[candidateIndex]
        return position <= candidate.endTime + tailTolerance ? candidate.id : nil
    }
}
