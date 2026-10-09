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
        smoothingBoundaryWords(align(words: words, intervals: intervals).map {
            AttributedTranscriptWord(word: $0.word, speakerID: $0.speakerIndex.flatMap { speakerIDs[$0] })
        })
    }

    static let boundaryRunMaximumWords = 2
    static let boundaryRunMaximumDuration: TimeInterval = 0.6
    static let contiguousSpeechGap: TimeInterval = 0.2
    static let clearPause: TimeInterval = 0.3

    /// Diarization boundaries jitter by a few hundred milliseconds, so the first or last
    /// word of a turn often lands on the neighbouring voice ("…sprint." · "Me" | "parece
    /// bien…"). A run of at most two short words that belongs to the voice across a clear
    /// pause, but is spoken without a break into another voice's turn, is a leftover of
    /// that other turn and joins it. Short replies keep their speaker, and so do runs at
    /// the start or end of the conversation.
    static func smoothingBoundaryWords(_ words: [AttributedTranscriptWord]) -> [AttributedTranscriptWord] {
        guard words.count > 2 else { return words }

        // Runs break on a speaker change or on a clear pause within one speaker.
        var runs: [Range<Int>] = []
        var start = 0
        for index in 1...words.count {
            let ends = index == words.count
                || words[index].speakerID != words[start].speakerID
                || words[index].word.startTime - words[index - 1].word.endTime >= clearPause
            if ends {
                runs.append(start..<index)
                start = index
            }
        }
        guard runs.count > 2 else { return words }

        func isShort(_ run: Range<Int>) -> Bool {
            run.count <= boundaryRunMaximumWords
                && words[run.upperBound - 1].word.endTime - words[run.lowerBound].word.startTime
                    <= boundaryRunMaximumDuration
        }

        // Decisions read the already smoothed speakers, and a leftover only joins a
        // substantial turn: two short phrases in a quick exchange ("¿Vale?" "Vale.")
        // must not trade speakers.
        var smoothed = words
        for position in 1..<(runs.count - 1) {
            let run = runs[position]
            let previous = runs[position - 1]
            let next = runs[position + 1]
            guard isShort(run) else { continue }

            let first = words[run.lowerBound].word
            let last = words[run.upperBound - 1].word
            let speaker = smoothed[run.lowerBound].speakerID
            let previousSpeaker = smoothed[previous.upperBound - 1].speakerID
            let nextSpeaker = smoothed[next.lowerBound].speakerID
            let gapBefore = first.startTime - words[previous.upperBound - 1].word.endTime
            let gapAfter = words[next.lowerBound].word.startTime - last.endTime

            let target: Speaker.ID?
            if gapAfter <= contiguousSpeechGap, gapBefore >= clearPause, !isShort(next),
               previousSpeaker == speaker, nextSpeaker != speaker {
                target = nextSpeaker
            } else if gapBefore <= contiguousSpeechGap, gapAfter >= clearPause, !isShort(previous),
                      nextSpeaker == speaker, previousSpeaker != speaker {
                target = previousSpeaker
            } else {
                continue
            }
            guard let target else { continue }
            for index in run {
                smoothed[index] = AttributedTranscriptWord(word: words[index].word, speakerID: target)
            }
        }
        return smoothed
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
