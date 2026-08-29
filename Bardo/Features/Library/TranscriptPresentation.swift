import Foundation

struct TranscriptWordCue: Identifiable, Equatable, Sendable {
    let id: TranscriptWord.ID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let characterRange: Range<Int>
}

struct TranscriptReadingBlock: Identifiable, Equatable, Sendable {
    let id: TranscriptSegment.ID
    let speakerID: Speaker.ID?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let segments: [TranscriptSegment]
    let text: String
    let wordCues: [TranscriptWordCue]

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
        var text = ""
        var wordCues: [TranscriptWordCue] = []

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                text.append(" ")
            }

            let displayText = segment.displayText
            let segmentOffset = text.count
            text.append(displayText)

            // Manual transcript edits deliberately keep the original Whisper evidence intact.
            // Once visible text differs from that evidence we cannot claim exact word alignment,
            // so karaoke highlighting is disabled only for that edited segment.
            guard segment.editedText == nil else { continue }

            wordCues.append(contentsOf: makeWordCues(
                for: segment,
                displayText: displayText,
                characterOffset: segmentOffset
            ))
        }

        return TranscriptReadingBlock(
            id: first.id,
            speakerID: first.speakerID,
            startTime: first.startTime,
            endTime: endTime,
            segments: segments,
            text: text,
            wordCues: wordCues
        )
    }

    private static func makeWordCues(
        for segment: TranscriptSegment,
        displayText: String,
        characterOffset: Int
    ) -> [TranscriptWordCue] {
        guard !displayText.isEmpty, !segment.words.isEmpty else { return [] }

        let orderedWords = segment.words.sorted {
            if $0.startTime == $1.startTime {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startTime < $1.startTime
        }

        var cues: [TranscriptWordCue] = []
        var searchStart = displayText.startIndex

        for word in orderedWords {
            let visibleWord = TranscriptTextSanitizer.sanitize(word.text)
            guard !visibleWord.isEmpty, searchStart < displayText.endIndex else { continue }

            let remainingRange = searchStart..<displayText.endIndex
            let match = displayText.range(of: visibleWord, range: remainingRange)
                ?? displayText.range(
                    of: visibleWord,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: remainingRange
                )

            guard let match else { continue }

            let lower = characterOffset + displayText.distance(from: displayText.startIndex, to: match.lowerBound)
            let upper = characterOffset + displayText.distance(from: displayText.startIndex, to: match.upperBound)

            cues.append(
                TranscriptWordCue(
                    id: word.id,
                    startTime: word.startTime,
                    endTime: word.endTime,
                    characterRange: lower..<upper
                )
            )
            searchStart = match.upperBound
        }

        return cues
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

    static func activeWordCue(
        at position: TimeInterval,
        in block: TranscriptReadingBlock,
        tailTolerance: TimeInterval = 0.12
    ) -> TranscriptWordCue? {
        guard position.isFinite,
              position >= 0,
              tailTolerance.isFinite,
              tailTolerance >= 0,
              !block.wordCues.isEmpty else {
            return nil
        }

        var lowerBound = 0
        var upperBound = block.wordCues.count - 1
        var candidateIndex: Int?

        while lowerBound <= upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if block.wordCues[middle].startTime <= position {
                candidateIndex = middle
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }

        guard let candidateIndex else { return nil }
        let candidate = block.wordCues[candidateIndex]
        return position <= candidate.endTime + tailTolerance ? candidate : nil
    }
}
