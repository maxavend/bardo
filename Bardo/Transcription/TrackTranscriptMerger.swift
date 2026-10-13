import Foundation

/// Combines a recording's two tracks, transcribed apart, into one conversation.
///
/// The microphone is always the person recording, so its turns belong to "You" and the
/// Mac's audio to "Others" until participants are told apart. When the call plays
/// through speakers the microphone hears it again a moment later; those echoed turns
/// repeat what the Mac's audio already said at the same time, and are left out. They
/// are recognised by their words and, through `isAcousticEcho`, by their sound.
enum TrackTranscriptMerger {
    /// How far apart the same word may be heard on both tracks and still be an echo.
    static let echoWindow: TimeInterval = 1.0
    /// The share of a microphone turn's words that must repeat the Mac's audio.
    static let echoShare = 0.6

    static func merge(
        system: [TranscriptSegment],
        microphone: [TranscriptSegment],
        isAcousticEcho: (TranscriptSegment) -> Bool = { _ in false }
    ) -> (segments: [TranscriptSegment], speakers: [Speaker]) {
        let own = microphone.filter { !isEcho($0, of: system) && !isAcousticEcho($0) }

        var speakers: [Speaker] = []
        var segments: [TranscriptSegment] = []
        if !own.isEmpty {
            let you = Speaker(role: .localUser)
            speakers.append(you)
            segments += own.map { assigned($0, to: you, source: .microphone) }
        }
        if !system.isEmpty {
            let others = Speaker(role: .others)
            speakers.append(others)
            segments += system.map { assigned($0, to: others, source: .system) }
        }

        segments.sort {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        return (segments, speakers)
    }

    /// Whether a microphone turn mostly repeats words the Mac's audio played around the
    /// same time.
    static func isEcho(_ segment: TranscriptSegment, of system: [TranscriptSegment]) -> Bool {
        let nearby = system.filter {
            $0.startTime - echoWindow <= segment.endTime && $0.endTime + echoWindow >= segment.startTime
        }
        guard !nearby.isEmpty else { return false }

        let spoken = timedWords(in: segment)
        guard !spoken.isEmpty else { return false }
        let played = nearby.flatMap(timedWords(in:))

        let repeated = spoken.filter { word in
            played.contains { $0.text == word.text && abs($0.time - word.time) <= echoWindow }
        }
        return Double(repeated.count) / Double(spoken.count) >= echoShare
    }

    private static func assigned(_ segment: TranscriptSegment, to speaker: Speaker, source: TranscriptSource) -> TranscriptSegment {
        var segment = segment
        segment.speakerID = speaker.id
        segment.source = source
        return segment
    }

    /// Each word with the moment it was said; without word timings the segment's words
    /// are spread evenly over its span.
    private static func timedWords(in segment: TranscriptSegment) -> [(text: String, time: TimeInterval)] {
        if !segment.words.isEmpty {
            return segment.words.compactMap { word in
                normalized(word.text).map { ($0, (word.startTime + word.endTime) / 2) }
            }
        }
        let words = segment.text.split(whereSeparator: \.isWhitespace).compactMap { normalized(String($0)) }
        guard !words.isEmpty else { return [] }
        let step = max(0, segment.endTime - segment.startTime) / Double(words.count)
        return words.enumerated().map { index, text in
            (text, segment.startTime + step * (Double(index) + 0.5))
        }
    }

    private static func normalized(_ word: String) -> String? {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let letters = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let result = String(String.UnicodeScalarView(letters))
        return result.isEmpty ? nil : result
    }
}
