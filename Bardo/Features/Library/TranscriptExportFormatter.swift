import Foundation

enum TranscriptExportStyle: Equatable, Sendable {
    case automatic
    case withoutSpeakers
    case withTimestamps
}

enum TranscriptExportFormatter {
    static func string(
        from transcript: Transcript,
        style: TranscriptExportStyle = .automatic
    ) -> String {
        switch style {
        case .automatic:
            return automaticString(from: transcript)
        case .withoutSpeakers:
            return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .withTimestamps:
            return timestampedString(from: transcript)
        }
    }

    private static func automaticString(from transcript: Transcript) -> String {
        let blocks = TranscriptReadingBlockBuilder.blocks(from: transcript.segments)
        guard hasSpeakerLabels(transcript), !blocks.isEmpty else {
            return transcript.text
        }

        return blocks.compactMap { block -> String? in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(speakerLabel(for: block, in: transcript)):\n\(text)"
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestampedString(from transcript: Transcript) -> String {
        let blocks = TranscriptReadingBlockBuilder.blocks(from: transcript.segments)
        guard !blocks.isEmpty else {
            return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let includesSpeakers = hasSpeakerLabels(transcript)
        return blocks.compactMap { block -> String? in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let timestamp = LibraryFormatting.duration(block.startTime)
            if includesSpeakers {
                return "[\(timestamp)] \(speakerLabel(for: block, in: transcript)):\n\(text)"
            }
            return "[\(timestamp)] \(text)"
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasSpeakerLabels(_ transcript: Transcript) -> Bool {
        transcript.diarizationMetadata != nil && !transcript.speakers.isEmpty
    }

    static func speakerLabel(for block: TranscriptReadingBlock, in transcript: Transcript) -> String {
        guard let speakerID = block.speakerID,
              let index = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else {
            return LibraryFormatting.localized("Unassigned Speaker")
        }

        let speaker = transcript.speakers[index]
        if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }

        return String(
            format: LibraryFormatting.localized("Speaker %@"),
            String(index + 1)
        )
    }
}
