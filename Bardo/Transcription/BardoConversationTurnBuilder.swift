import Foundation

enum BardoConversationTurnBuilder {
    static let mediumPause: TimeInterval = 0.45
    static let strongPause: TimeInterval = 1.2
    static let softMaximumDuration: TimeInterval = 32

    static func build(from words: [AttributedTranscriptWord]) -> [TranscriptSegment] {
        let validWords = words.filter {
            $0.word.startTime.isFinite
                && $0.word.endTime.isFinite
                && $0.word.endTime >= $0.word.startTime
                && !$0.word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !validWords.isEmpty else { return [] }

        var turns: [TranscriptSegment] = []
        var current: [AttributedTranscriptWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = joinText(current.map { $0.word.text })
            guard !text.isEmpty else {
                current.removeAll(keepingCapacity: true)
                return
            }
            turns.append(
                TranscriptSegment(
                    startTime: first.word.startTime,
                    endTime: last.word.endTime,
                    speakerID: first.speakerID,
                    text: text,
                    words: current.map(\.word)
                )
            )
            current.removeAll(keepingCapacity: true)
        }

        for word in validWords {
            if let previous = current.last,
               shouldStartNewTurn(previous: previous, next: word, currentStart: current[0].word.startTime) {
                flush()
            }
            current.append(word)
        }
        flush()
        return turns
    }

    private static func shouldStartNewTurn(
        previous: AttributedTranscriptWord,
        next: AttributedTranscriptWord,
        currentStart: TimeInterval
    ) -> Bool {
        if previous.speakerID != next.speakerID {
            return true
        }

        let gap = max(0, next.word.startTime - previous.word.endTime)
        if gap >= strongPause {
            return true
        }

        let sentenceEnded = previous.word.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .last.map { ".!?…".contains($0) } ?? false
        if sentenceEnded && gap >= mediumPause {
            return true
        }

        let duration = next.word.endTime - currentStart
        return duration >= softMaximumDuration && (sentenceEnded || gap >= mediumPause)
    }

    private static func joinText(_ tokens: [String]) -> String {
        var result = ""
        for token in tokens {
            guard !token.isEmpty else { continue }
            if result.isEmpty {
                result = token
            } else if token.first.map({ $0.isWhitespace || ",.!?;:%)]}".contains($0) }) == true {
                result += token
            } else {
                result += " " + token
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
