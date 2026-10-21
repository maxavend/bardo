import Foundation

/// A transcript as plain text to copy, share or export: the conversation's title and date,
/// then one block per stretch of speech, headed by who spoke and when.
///
/// Blocks follow the conversation rather than the clock: everything one person says
/// without a long pause is one block, however long, and a new block starts when someone
/// else speaks or after a pause. Without speakers, long stretches are still split so the
/// text stays readable.
struct TranscriptTextFormatter {
    /// Without speakers to break it up, a block ends at the first segment past this length.
    static let unlabeledBlockLength: TimeInterval = 120

    struct Block: Equatable {
        let speaker: String?
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    let title: String
    let date: Date?
    let duration: TimeInterval?
    let localName: String?
    /// Sections become headings and moments are listed where they were marked.
    let notes: RecordingNotes

    init(
        title: String,
        date: Date? = nil,
        duration: TimeInterval? = nil,
        notes: RecordingNotes = RecordingNotes(),
        localName: String? = LocalSpeakerName.current
    ) {
        self.title = title
        self.date = date
        self.duration = duration
        self.notes = notes
        self.localName = localName
    }

    func text(for transcript: Transcript) -> String {
        var lines = [title]
        var details: [String] = []
        if let date { details.append(date.formatted(.dateTime.day().month(.wide).year())) }
        if let duration { details.append(LibraryFormatting.duration(duration)) }
        if !details.isEmpty { lines.append(details.joined(separator: " · ")) }

        let blocks = blocks(for: transcript)
        let placement = TranscriptNotePlacement(notes: notes, paragraphStarts: blocks.map(\.start))
        if !placement.leadingMoments.isEmpty {
            lines.append("")
            lines += placement.leadingMoments.map(momentLine)
        }
        for (index, block) in blocks.enumerated() {
            for section in placement.sections(before: index) {
                lines += ["", sectionLine(section)]
            }
            lines.append("")
            let range = "\(LibraryFormatting.duration(block.start))–\(LibraryFormatting.duration(block.end))"
            lines.append(block.speaker.map { "\($0) (\(range))" } ?? range)
            lines.append(block.text)
            lines += placement.moments(after: index).map(momentLine)
        }
        for section in placement.trailingSections {
            lines += ["", sectionLine(section)]
        }
        return lines.joined(separator: "\n")
    }

    /// In capitals, so a section reads apart from the speakers' headings.
    private func sectionLine(_ section: RecordingSection) -> String {
        "\(section.title.uppercased()) · \(LibraryFormatting.duration(section.start))"
    }

    private func momentLine(_ moment: RecordingMoment) -> String {
        let heading = "⚑ \(LibraryFormatting.duration(moment.time)) · \(moment.title)"
        return moment.note.map { "\(heading): \($0)" } ?? heading
    }

    func blocks(for transcript: Transcript) -> [Block] {
        let names = Dictionary(
            transcript.speakers.map { ($0.id, transcript.displayName(for: $0, localName: localName)) },
            uniquingKeysWith: { first, _ in first }
        )
        // The same paragraphs as on screen: each turn on its own, of a comfortable length.
        let segments = transcript.segments
            .sorted { $0.startTime < $1.startTime }
            .filter { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return TranscriptParagraphing.paragraphs(of: segments).flatMap { group -> [[TranscriptSegment]] in
            // Without names, long stretches still get a heading every couple of minutes,
            // so a time can be found.
            guard let first = group.first, first.speakerID.flatMap({ names[$0] }) == nil else { return [group] }
            var parts: [[TranscriptSegment]] = [[]]
            var partStart = first.startTime
            for segment in group {
                if !parts[parts.count - 1].isEmpty, segment.endTime - partStart > Self.unlabeledBlockLength {
                    parts.append([])
                    partStart = segment.startTime
                }
                parts[parts.count - 1].append(segment)
            }
            return parts
        }.compactMap { group in
            guard let first = group.first else { return nil }
            return Block(
                speaker: first.speakerID.flatMap { names[$0] },
                start: first.startTime,
                end: group.map(\.endTime).max() ?? first.endTime,
                text: group.map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            )
        }
    }
}
