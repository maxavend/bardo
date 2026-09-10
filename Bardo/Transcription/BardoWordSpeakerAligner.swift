import Foundation

struct SpeakerAttributedWord: Equatable, Sendable {
    let word: TranscriptWord
    let speakerIndex: Int?
}

struct AttributedTranscriptWord: Equatable, Sendable {
    let word: TranscriptWord
    let speakerID: Speaker.ID?

    init(word: TranscriptWord, speakerID: Speaker.ID? = nil) {
        self.word = word
        self.speakerID = speakerID
    }
}

enum BardoWordSpeakerAligner {
    static func align(
        words: [TranscriptWord],
        intervals: [DiarizationInterval]
    ) -> [SpeakerAttributedWord] {
        let validIntervals = intervals.filter {
            $0.speakerIndex >= 0
                && $0.startTime.isFinite
                && $0.endTime.isFinite
                && $0.endTime > $0.startTime
        }

        return words.map { word in
            SpeakerAttributedWord(
                word: word,
                speakerIndex: bestSpeakerIndex(for: word, intervals: validIntervals)
            )
        }
    }

    static func attributed(
        words: [TranscriptWord],
        intervals: [DiarizationInterval],
        speakerIDs: [Int: Speaker.ID]
    ) -> [AttributedTranscriptWord] {
        align(words: words, intervals: intervals).map {
            AttributedTranscriptWord(word: $0.word, speakerID: $0.speakerIndex.flatMap { speakerIDs[$0] })
        }
    }

    private static func bestSpeakerIndex(
        for word: TranscriptWord,
        intervals: [DiarizationInterval]
    ) -> Int? {
        guard word.startTime.isFinite, word.endTime.isFinite, word.endTime >= word.startTime else {
            return nil
        }

        var scores: [Int: TimeInterval] = [:]
        if word.startTime == word.endTime {
            for interval in intervals where word.startTime >= interval.startTime && word.startTime <= interval.endTime {
                scores[interval.speakerIndex, default: 0] += 0.000_001
            }
        } else {
            for interval in intervals {
                let overlap = max(0, min(word.endTime, interval.endTime) - max(word.startTime, interval.startTime))
                if overlap > 0 {
                    scores[interval.speakerIndex, default: 0] += overlap
                }
            }
        }

        return scores
            .filter { $0.value > 0 }
            .max {
                if $0.value == $1.value { return $0.key > $1.key }
                return $0.value < $1.value
            }?
            .key
    }
}
