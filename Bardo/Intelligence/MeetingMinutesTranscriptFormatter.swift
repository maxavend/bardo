import Foundation

enum MeetingMinutesTranscriptFormatter {
    static let defaultChunkCharacterLimit = 6_500

    static func formattedLines(from transcript: Transcript) -> [String] {
        let speakerLabels = Dictionary(uniqueKeysWithValues: transcript.speakers.enumerated().map { index, speaker in
            let trimmedName = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (trimmedName?.isEmpty == false) ? trimmedName! : "Speaker \(index + 1)"
            return (speaker.id, label)
        })

        return transcript.segments.compactMap { segment in
            let text = segment.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let seconds = max(0, Int(segment.startTime.rounded(.down)))
            let timestamp = timestampString(seconds: seconds)
            let speaker = segment.speakerID.flatMap { speakerLabels[$0] } ?? "Speaker"
            return "[t=\(seconds)s | \(timestamp)] \(speaker): \(text)"
        }
    }

    static func chunks(
        from transcript: Transcript,
        maxCharacters: Int = defaultChunkCharacterLimit
    ) -> [String] {
        precondition(maxCharacters > 0)

        var result: [String] = []
        var current = ""

        for line in formattedLines(from: transcript) {
            let pieces = splitLongLine(line, maxCharacters: maxCharacters)

            for piece in pieces {
                if current.isEmpty {
                    current = piece
                } else if current.count + 1 + piece.count <= maxCharacters {
                    current += "\n" + piece
                } else {
                    result.append(current)
                    current = piece
                }
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }

    private static func splitLongLine(_ line: String, maxCharacters: Int) -> [String] {
        guard line.count > maxCharacters else { return [line] }

        var pieces: [String] = []
        var start = line.startIndex

        while start < line.endIndex {
            let end = line.index(start, offsetBy: maxCharacters, limitedBy: line.endIndex) ?? line.endIndex
            pieces.append(String(line[start..<end]))
            start = end
        }

        return pieces
    }

    private static func timestampString(seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }
}
