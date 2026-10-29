using Bardo.Domain;

namespace Bardo.Transcription;

/// <summary>How loud a track is over time: one level every 20 ms, placed on the timeline.</summary>
public sealed class TrackLoudness
{
    public const double FrameDuration = 0.02;

    /// <summary>The audio loader must deliver 16 kHz mono samples, as Whisper's does.</summary>
    public const double SampleRate = 16_000;

    private const double ChunkDuration = 60;
    private const float SilenceFloor = 1e-6f;

    private readonly float[] _levels;

    public TrackLoudness(double offset, IEnumerable<float> levels)
    {
        Offset = offset;
        _levels = [.. levels];
    }

    public double Offset { get; }

    public IReadOnlyList<float> Levels => _levels;

    /// <summary>
    /// Reads the audio a minute at a time, so even a long meeting never needs its whole
    /// audio in memory. <paramref name="loadSamples"/> returns the 16 kHz mono samples
    /// between two moments of the file, in seconds.
    /// </summary>
    public static TrackLoudness Measure(Func<double, double, float[]> loadSamples, double duration, double offset)
    {
        var samplesPerFrame = (int)(SampleRate * FrameDuration);
        var levels = new List<float>(double.IsFinite(duration) && duration > 0 ? (int)(duration / FrameDuration) + 1 : 0);

        var start = 0.0;
        while (start < duration)
        {
            var end = Math.Min(duration, start + ChunkDuration);
            var samples = loadSamples(start, end);
            var index = 0;
            while (index + samplesPerFrame <= samples.Length)
            {
                var energy = 0f;
                for (var sample = index; sample < index + samplesPerFrame; sample++)
                {
                    energy += samples[sample] * samples[sample];
                }
                levels.Add(MathF.Log10(MathF.Sqrt(energy / samplesPerFrame) + SilenceFloor));
                index += samplesPerFrame;
            }
            start = end;
        }
        return new TrackLoudness(offset, levels);
    }

    /// <summary>
    /// The loudness of audio read a stretch at a time, as a decoder delivers it: 16 kHz
    /// mono samples from the start of the file.
    /// </summary>
    public static async Task<TrackLoudness> MeasureAsync(IAsyncEnumerable<float[]> chunks, double offset, CancellationToken cancellationToken = default)
    {
        var samplesPerFrame = (int)(SampleRate * FrameDuration);
        var levels = new List<float>();
        var energy = 0f;
        var inFrame = 0;
        await foreach (var chunk in chunks.WithCancellation(cancellationToken).ConfigureAwait(false))
        {
            // A frame can straddle two stretches.
            foreach (var sample in chunk)
            {
                energy += sample * sample;
                if (++inFrame < samplesPerFrame) continue;
                levels.Add(MathF.Log10(MathF.Sqrt(energy / samplesPerFrame) + SilenceFloor));
                energy = 0;
                inFrame = 0;
            }
        }
        return new TrackLoudness(offset, levels);
    }

    /// <summary>The levels between two moments on the timeline, or null where the track has none.</summary>
    public ReadOnlyMemory<float>? LevelsFrom(double start, int count)
    {
        var first = (int)Math.Round((start - Offset) / FrameDuration, MidpointRounding.AwayFromZero);
        if (first < 0 || count <= 0 || first + count > _levels.Length) return null;
        return _levels.AsMemory(first, count);
    }
}

/// <summary>
/// Recognises a microphone turn that is the call heard again through the speakers: its
/// loudness rises and falls with the computer's audio a few milliseconds later. It works in
/// any language and even when Whisper misheard the echo.
/// </summary>
public static class TrackEchoDetector
{
    /// <summary>Speakers to microphone takes a few milliseconds; allow for slow audio paths.</summary>
    public const double MaximumDelay = 0.3;

    /// <summary>
    /// Measured on a Mac: an echo follows the call at 0.6–0.7, a different voice at about 0.
    /// </summary>
    public const float Threshold = 0.5f;

    /// <summary>Shorter turns carry too little shape to compare.</summary>
    public const double MinimumDuration = 0.5;

    public static bool IsEcho(TranscriptSegment segment, TrackLoudness microphone, TrackLoudness system)
    {
        var span = segment.EndTime - segment.StartTime;
        if (!(span >= MinimumDuration)) return false;
        var count = (int)Math.Round(span / TrackLoudness.FrameDuration, MidpointRounding.AwayFromZero);
        if (microphone.LevelsFrom(segment.StartTime, count) is not { } spoken) return false;

        var maximumLag = (int)Math.Round(MaximumDelay / TrackLoudness.FrameDuration, MidpointRounding.AwayFromZero);
        for (var lag = 0; lag <= maximumLag; lag++)
        {
            var playedAt = segment.StartTime - lag * TrackLoudness.FrameDuration;
            if (system.LevelsFrom(playedAt, count) is { } played && Correlation(spoken.Span, played.Span) >= Threshold)
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>Pearson correlation; a flat (silent) track correlates with nothing.</summary>
    public static float Correlation(ReadOnlySpan<float> a, ReadOnlySpan<float> b)
    {
        float count = a.Length;
        if (count <= 1 || a.Length != b.Length) return 0;
        var sumA = 0f;
        var sumB = 0f;
        for (var index = 0; index < a.Length; index++)
        {
            sumA += a[index];
            sumB += b[index];
        }
        var meanA = sumA / count;
        var meanB = sumB / count;
        var product = 0f;
        var varianceA = 0f;
        var varianceB = 0f;
        for (var index = 0; index < a.Length; index++)
        {
            product += (a[index] - meanA) * (b[index] - meanB);
            varianceA += (a[index] - meanA) * (a[index] - meanA);
            varianceB += (b[index] - meanB) * (b[index] - meanB);
        }
        if (!(varianceA > 1e-3f) || !(varianceB > 1e-3f)) return 0;
        return product / MathF.Sqrt(varianceA * varianceB);
    }
}
