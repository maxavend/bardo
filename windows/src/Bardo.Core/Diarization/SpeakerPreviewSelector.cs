using Bardo.Domain;

namespace Bardo.Diarization;

/// <summary>A stretch of audio to play so the person can recognise a speaker.</summary>
public sealed record SpeakerPreview(Guid SpeakerId, double StartTime, double EndTime);

public static class SpeakerPreviewSelector
{
    public const double MaximumDuration = 10;

    /// <summary>
    /// For each speaker, the start of their longest continuous stretch, at most
    /// <paramref name="maxDuration"/> (never more than ten seconds) long.
    /// </summary>
    public static IReadOnlyList<SpeakerPreview> Previews(Transcript transcript, double maxDuration = MaximumDuration)
    {
        var durationLimit = Math.Min(maxDuration, MaximumDuration);
        if (!(durationLimit > 0) || !double.IsFinite(durationLimit)) return [];

        var previews = new List<SpeakerPreview>();
        foreach (var speaker in transcript.Speakers)
        {
            if (LongestContinuousInterval(speaker.Id, transcript) is not { } interval) continue;
            previews.Add(new SpeakerPreview(speaker.Id, interval.Start, Math.Min(interval.End, interval.Start + durationLimit)));
        }
        return previews;
    }

    private static (double Start, double End)? LongestContinuousInterval(Guid speakerId, Transcript transcript)
    {
        var intervals = transcript.Segments
            .Where(segment => segment.SpeakerId == speakerId)
            .Select(SpokenInterval)
            .OfType<(double Start, double End)>()
            .OrderBy(interval => interval.Start)
            .ThenBy(interval => interval.End)
            .ToList();
        if (intervals.Count == 0) return null;

        var current = intervals[0];
        var longest = current;
        foreach (var interval in intervals.Skip(1))
        {
            if (interval.Start <= current.End)
            {
                current = (current.Start, Math.Max(current.End, interval.End));
            }
            else
            {
                if (Duration(current) > Duration(longest)) longest = current;
                current = interval;
            }
        }
        if (Duration(current) > Duration(longest)) longest = current;
        return longest;
    }

    /// <summary>A segment's span, narrowed to its first and last timed words when it has them.</summary>
    private static (double Start, double End)? SpokenInterval(TranscriptSegment segment)
    {
        if (!double.IsFinite(segment.StartTime) || !double.IsFinite(segment.EndTime)
            || segment.StartTime < 0 || !(segment.EndTime > segment.StartTime))
        {
            return null;
        }
        var words = segment.Words
            .Where(word => double.IsFinite(word.StartTime)
                && double.IsFinite(word.EndTime)
                && word.StartTime >= segment.StartTime
                && word.EndTime <= segment.EndTime
                && word.EndTime > word.StartTime)
            .ToList();
        if (words.Count == 0) return (segment.StartTime, segment.EndTime);
        return (words.Min(word => word.StartTime), words.Max(word => word.EndTime));
    }

    private static double Duration((double Start, double End) interval) => interval.End - interval.Start;
}
