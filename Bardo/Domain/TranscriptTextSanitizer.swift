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
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([¿¡])\s+"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return capitalizeSentenceStarts(value)
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
