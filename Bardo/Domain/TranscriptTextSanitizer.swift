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
}
