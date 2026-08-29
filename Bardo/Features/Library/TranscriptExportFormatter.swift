import Foundation

enum TranscriptExportFormatter {
    static func string(from transcript: Transcript) -> String {
        let blocks = TranscriptReadingBlockBuilder.blocks(from: transcript.segments)
        guard transcript.diarizationMetadata != nil,
              !transcript.speakers.isEmpty,
              !blocks.isEmpty else {
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
