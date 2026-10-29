using Bardo.Domain;

namespace Bardo.Transcription;

/// <summary>
/// Recognises text written over silence. Whisper fills silent windows with stock phrases
/// from the subtitles it learned from ("Thank you.", "Gracias."): a muted microphone gave
/// one every 22 seconds for an hour. Text whose audio never rises above a whisper of room
/// noise is not something anyone said.
/// </summary>
public static class TrackSilenceDetector
{
    /// <summary>
    /// About −60 dBFS, as <see cref="TrackLoudness"/> levels (log10 of the RMS). Room noise on
    /// a microphone sits near it and quiet speech peaks well above it; a muted microphone
    /// records digital silence, far below.
    /// </summary>
    public const float Threshold = -3;

    /// <summary>Whisper's timestamps can be a little early or late; the audio around them counts.</summary>
    public const double Margin = 0.2;

    public static bool IsSilent(TranscriptSegment segment, TrackLoudness loudness)
    {
        var start = Math.Max(loudness.Offset, segment.StartTime - Margin);
        var count = (int)Math.Round((segment.EndTime + Margin - start) / TrackLoudness.FrameDuration, MidpointRounding.AwayFromZero);
        var first = (int)Math.Round((start - loudness.Offset) / TrackLoudness.FrameDuration, MidpointRounding.AwayFromZero);
        var available = Math.Min(count, loudness.Levels.Count - first);
        // Where the track has no levels, there is nothing to judge by.
        if (available <= 0 || loudness.LevelsFrom(start, available) is not { } levels) return false;
        foreach (var level in levels.Span)
        {
            if (level >= Threshold) return false;
        }
        return true;
    }
}
