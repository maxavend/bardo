import SwiftUI

struct TranscriptKaraokeText: View {
    let block: TranscriptReadingBlock
    @ObservedObject var timeline: AudioPlaybackTimeline

    var body: some View {
        renderedText
            .font(.body)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedText: Text {
        guard let cue = TranscriptPlaybackMapping.activeWordCue(
            at: timeline.position,
            in: block
        ),
        cue.characterRange.lowerBound >= 0,
        cue.characterRange.upperBound <= block.text.count else {
            return Text(block.text)
        }

        let lower = block.text.index(
            block.text.startIndex,
            offsetBy: cue.characterRange.lowerBound
        )
        let upper = block.text.index(
            block.text.startIndex,
            offsetBy: cue.characterRange.upperBound
        )

        let before = String(block.text[..<lower])
        let active = String(block.text[lower..<upper])
        let after = String(block.text[upper...])

        // Color changes do not affect text metrics, so the 10 Hz playback tick does not
        // continuously invalidate layout while the active word advances.
        return Text(before)
            + Text(active).foregroundColor(.accentColor)
            + Text(after)
    }
}
