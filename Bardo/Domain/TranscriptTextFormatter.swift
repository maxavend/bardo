import Foundation

/// A transcript as plain text to copy, share or export: the conversation's title and date,
/// then one block per stretch of speech, headed by who spoke and when.
///
/// Blocks follow the conversation rather than the clock: everything one person says
/// without a long pause is one block, however long, and a new block starts when someone
/// else speaks or after a pause. Without speakers, long stretches are still split so the
/// text stays readable.
struct TranscriptTextFormatter {
    /// A silence at least this long starts a new block.
    static let pauseBreak: TimeInterval = 8
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

    init(title: String, date: Date? = nil, duration: TimeInterval? = nil, localName: String? = LocalSpeakerName.current) {
        self.title = title
        self.date = date
        self.duration = duration
        self.localName = localName
    }

    func text(for transcript: Transcript) -> String {
        var lines = [title]
        var details: [String] = []
        if let date { details.append(date.formatted(.dateTime.day().month(.wide).year())) }
        if let duration { details.append(LibraryFormatting.duration(duration)) }
        if !details.isEmpty { lines.append(details.joined(separator: " · ")) }

        for block in blocks(for: transcript) {
            lines.append("")
            let range = "\(LibraryFormatting.duration(block.start))–\(LibraryFormatting.duration(block.end))"
            lines.append(block.speaker.map { "\($0) (\(range))" } ?? range)
            lines.append(block.text)
        }
        return lines.joined(separator: "\n")
    }

    func blocks(for transcript: Transcript) -> [Block] {
        let names = Dictionary(
            transcript.speakers.map { ($0.id, transcript.displayName(for: $0, localName: localName)) },
            uniquingKeysWith: { first, _ in first }
        )
        var blocks: [Block] = []
        var speakerID: Speaker.ID?
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var words: [String] = []

        func close() {
            guard !words.isEmpty else { return }
            blocks.append(Block(
                speaker: speakerID.flatMap { names[$0] },
                start: start,
                end: end,
                text: words.joined(separator: " ")
            ))
            words = []
        }

        for segment in transcript.segments.sorted(by: { $0.startTime < $1.startTime }) {
            let text = segment.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !words.isEmpty {
                let otherSpeaker = segment.speakerID != speakerID
                let paused = segment.startTime - end >= Self.pauseBreak
                let tooLong = speakerID.flatMap({ names[$0] }) == nil && end - start >= Self.unlabeledBlockLength
                if otherSpeaker || paused || tooLong { close() }
            }
            if words.isEmpty {
                speakerID = segment.speakerID
                start = segment.startTime
                end = segment.endTime
            }
            end = max(end, segment.endTime)
            words.append(text)
        }
        close()
        return blocks
    }
}
