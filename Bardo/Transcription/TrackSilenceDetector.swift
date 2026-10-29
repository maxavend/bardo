import Foundation

/// Recognises text written over silence. Whisper fills silent windows with stock phrases
/// from the subtitles it learned from ("Thank you.", "Gracias."): a muted microphone gave
/// one every 22 seconds for an hour. Text whose audio never rises above a whisper of room
/// noise is not something anyone said.
enum TrackSilenceDetector {
    /// About −60 dBFS, as `TrackLoudness` levels (log10 of the RMS). Room noise on a
    /// microphone sits near it and quiet speech peaks well above it; a muted microphone
    /// records digital silence, far below.
    static let threshold: Float = -3
    /// Whisper's timestamps can be a little early or late; the audio around them counts.
    static let margin: TimeInterval = 0.2

    static func isSilent(_ segment: TranscriptSegment, in loudness: TrackLoudness) -> Bool {
        let start = max(loudness.offset, segment.startTime - margin)
        let count = Int(((segment.endTime + margin - start) / TrackLoudness.frameDuration).rounded())
        let available = min(count, loudness.levels.count - Int(((start - loudness.offset) / TrackLoudness.frameDuration).rounded()))
        // Where the track has no levels, there is nothing to judge by.
        guard available > 0, let levels = loudness.levels(from: start, count: available) else { return false }
        return levels.allSatisfy { $0 < threshold }
    }
}
