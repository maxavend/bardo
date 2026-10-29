using Bardo.Domain;

namespace Bardo.Library;

/// <summary>A stretch of a recording, in seconds.</summary>
public readonly record struct TimeRange(double Start, double End)
{
    public bool Contains(double seconds) => seconds >= Start && seconds <= End;
}

/// <summary>
/// Lets playback hear only some of the participants: what the others say, and the pauses
/// around it, are skipped. A little air is kept around each turn, and short gaps between
/// kept turns play through, so speech never sounds clipped or jumpy.
/// </summary>
public static class SpeakerPlaybackFilter
{
    public const double Padding = 0.25;

    /// <summary>Gaps between kept turns shorter than this play through instead of being jumped.</summary>
    public const double ShortestSkip = 1;

    /// <summary>The stretches of a recording <paramref name="duration"/> long where none of <paramref name="speakers"/> is talking.</summary>
    public static IReadOnlyList<TimeRange> SkippedRanges(Transcript transcript, IReadOnlySet<Guid> speakers, double duration)
    {
        if (!(duration > 0)) return [];
        var turns = transcript.Segments
            .Where(segment => segment.SpeakerId is { } id && speakers.Contains(id))
            .Select(segment => new TimeRange(
                Math.Max(0, segment.StartTime - Padding),
                Math.Min(duration, Math.Max(0, segment.EndTime + Padding))));
        var skipped = new List<TimeRange>();
        double heardUntil = 0;
        foreach (var turn in Merged(turns))
        {
            if (turn.Start - heardUntil >= ShortestSkip) skipped.Add(new TimeRange(heardUntil, turn.Start));
            heardUntil = Math.Max(heardUntil, turn.End);
        }
        if (duration - heardUntil >= ShortestSkip) skipped.Add(new TimeRange(heardUntil, duration));
        return skipped;
    }

    /// <summary>The ranges in order, with overlapping or touching ones joined.</summary>
    public static IReadOnlyList<TimeRange> Merged(IEnumerable<TimeRange> ranges)
    {
        var result = new List<TimeRange>();
        foreach (var range in ranges.OrderBy(range => range.Start))
        {
            if (result.Count > 0 && range.Start <= result[^1].End)
            {
                result[^1] = result[^1] with { End = Math.Max(result[^1].End, range.End) };
            }
            else
            {
                result.Add(range);
            }
        }
        return result;
    }
}
