import Foundation

/// How a transcript is broken into paragraphs for reading: each turn of the
/// conversation on its own, and within a turn, paragraphs of a comfortable length. A
/// short breath does not leave a line of five words behind, and a long monologue does
/// not become a wall of text.
enum TranscriptParagraphing {
    /// A paragraph shorter than this keeps going through ordinary pauses.
    static let minimumWords = 20
    /// Past this, a paragraph ends at the next sentence that ends.
    static let comfortableWords = 70
    /// A paragraph that still has not reached a sentence's end stops here regardless.
    static let maximumWords = 120
    /// A pause long enough to end a paragraph once it has its minimum.
    static let pause: TimeInterval = 2.5
    /// A silence that always starts a new paragraph.
    static let silence: TimeInterval = 6

    /// The segments, in order, grouped into paragraphs.
    static func paragraphs(of segments: [TranscriptSegment]) -> [[TranscriptSegment]] {
        var paragraphs: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var words = 0

        for segment in segments {
            if let last = current.last {
                let gap = segment.startTime - last.endTime
                let speakerChanged = segment.speakerID != last.speakerID
                let endsSentence = last.displayText.trimmingCharacters(in: .whitespaces).last.map { ".?!…".contains($0) } ?? false
                let shouldBreak = speakerChanged
                    || gap >= silence
                    || (gap >= pause && words >= minimumWords)
                    || (words >= comfortableWords && endsSentence)
                    || words >= maximumWords
                if shouldBreak {
                    paragraphs.append(current)
                    current = []
                    words = 0
                }
            }
            current.append(segment)
            words += wordCount(segment.displayText)
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
