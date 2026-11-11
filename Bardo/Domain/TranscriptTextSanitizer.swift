import Foundation

enum TranscriptTextSanitizer {
    private static let whisperControlTokenPattern = #"<\|[^>]*\|>"#

    static func sanitize(_ text: String) -> String {
        let withoutControlTokens = text.replacingOccurrences(
            of: whisperControlTokenPattern,
            with: " ",
            options: .regularExpression
        )

        return withoutControlTokens
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Conservative cleanup for raw ASR output. It improves presentation and fixes a
    /// small set of unambiguous product-design terms without rewriting what was said.
    static func normalizeRecognizedText(_ text: String) -> String {
        var value = sanitize(text)
        let replacements: [(String, String)] = [
            (#"(?i)\bfigma\b"#, "Figma"),
            (#"(?i)\bempty[- ]?state\b"#, "empty state"),
            (#"(?i)\banti[- ]?state\b"#, "empty state"),
            (#"(?i)\bsupport(?:ing| in)[- ]?text\b"#, "supporting text"),
            (#"(?i)\bdesign[- ]?system\b"#, "design system"),
            (#"(?i)\bhand[- ]?off\b"#, "handoff"),
            (#"(?i)\bbread[- ]?crumbs\b"#, "breadcrumbs")
        ]

        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        value = value
            .replacingOccurrences(of: #"\.{3,}"#, with: "…", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?…])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([¿¡])\s+"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return capitalizeSentenceStarts(value)
    }

    static func wordKey(_ word: some StringProtocol) -> String {
        String(word.filter { $0.isLetter || $0.isNumber })
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whisper can emit many copies of a word at the same timestamp. Only trim
    /// long, implausibly timed runs when the visible text and word timings agree.
    static func removingRecognitionLoop(from segment: TranscriptSegment) -> TranscriptSegment {
        let words = segment.words
        guard segment.editedText == nil, words.count >= 8 else { return segment }
        let tokens = segment.text.split(whereSeparator: \.isWhitespace)
        guard tokens.count == words.count else { return segment }
        let keys = words.map { wordKey($0.text) }
        guard zip(tokens, keys).allSatisfy({ wordKey($0.0) == $0.1 }) else { return segment }

        var removed = IndexSet()
        var start = 0
        while start < keys.count {
            var end = start + 1
            while end < keys.count, keys[end] == keys[start] { end += 1 }
            let count = end - start
            if count >= 8, !keys[start].isEmpty {
                let range = words[start..<end]
                let duration = words[end - 1].endTime - words[start].startTime
                let collapsed = range.filter { $0.endTime - $0.startTime < 0.01 }.count
                if duration < Double(count) * 0.075 || collapsed * 2 >= count {
                    removed.insert(integersIn: (start + 3)..<end)
                }
            }
            start = end
        }
        guard !removed.isEmpty else { return segment }
        let kept = words.indices.filter { !removed.contains($0) }
        var cleaned = segment
        cleaned.text = kept.map { tokens[$0] }.joined(separator: " ")
        cleaned.words = kept.map { words[$0] }
        return cleaned
    }

    private static func capitalizeSentenceStarts(_ text: String) -> String {
        var result = ""
        var shouldCapitalize = true

        for character in text {
            if shouldCapitalize, character.isLetter {
                result.append(contentsOf: String(character).uppercased())
                shouldCapitalize = false
            } else {
                result.append(character)
                if character.isLetter || character.isNumber {
                    shouldCapitalize = false
                }
            }

            if character == "." || character == "!" || character == "?" || character == "…" {
                shouldCapitalize = true
            }
        }

        return result
    }
}
