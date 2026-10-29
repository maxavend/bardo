using Bardo.Domain;

namespace Bardo.Library;

/// <summary>
/// The shape of a recording's sound, for drawing: loudness in bins from 0 (silence) to 1,
/// on a decibel scale so quiet speech still shows, and which participant each bin belongs to.
/// </summary>
public static class Waveform
{
    /// <summary>Bins kept for a whole recording; the view pools them into the bars that fit.</summary>
    public const int OverviewBins = 800;

    /// <summary>Decoding rate for drawing: plenty to see speech, light to decode.</summary>
    public const int SampleRate = 8_000;

    /// <summary>Quieter than this draws as silence.</summary>
    public const double FloorDecibels = -50;

    /// <summary>Loudness on the drawing's scale, from an RMS or peak amplitude.</summary>
    public static float Level(double amplitude)
    {
        if (amplitude <= 0 || !double.IsFinite(amplitude)) return 0;
        var decibels = 20 * Math.Log10(amplitude);
        return (float)Math.Clamp((decibels - FloorDecibels) / -FloorDecibels, 0, 1);
    }

    /// <summary>The loudness of a whole recording in <paramref name="bins"/> equal stretches.</summary>
    public static async Task<float[]> OverviewAsync(
        IAudioDecoder decoder,
        string path,
        double duration,
        CancellationToken cancellationToken,
        int bins = OverviewBins)
    {
        var samplesPerBin = Math.Max(1, (long)Math.Ceiling(Math.Max(duration, 0.1) * SampleRate / bins));
        var levels = new List<float>(bins);
        double sum = 0;
        long count = 0;
        await foreach (var chunk in decoder.ReadMonoAsync(path, SampleRate, TimeSpan.FromMinutes(1), cancellationToken).ConfigureAwait(false))
        {
            foreach (var sample in chunk)
            {
                sum += sample * sample;
                if (++count < samplesPerBin) continue;
                levels.Add(Level(Math.Sqrt(sum / count)));
                sum = 0;
                count = 0;
            }
        }
        if (count > 0) levels.Add(Level(Math.Sqrt(sum / count)));
        return [.. levels];
    }

    /// <summary>
    /// <paramref name="levels"/> pooled or stretched to <paramref name="count"/> bars. Pooling
    /// keeps each group's loudest bin, so a short word is never lost between bars.
    /// </summary>
    public static float[] Bars(IReadOnlyList<float> levels, int count)
    {
        if (count <= 0 || levels.Count == 0) return [];
        var bars = new float[count];
        for (var bar = 0; bar < count; bar++)
        {
            var start = (int)((long)bar * levels.Count / count);
            var end = Math.Max(start + 1, (int)((long)(bar + 1) * levels.Count / count));
            float loudest = 0;
            for (var index = start; index < end && index < levels.Count; index++) loudest = Math.Max(loudest, levels[index]);
            bars[bar] = loudest;
        }
        return bars;
    }

    /// <summary>
    /// Which participant speaks during each of <paramref name="count"/> equal stretches of
    /// the recording, as an index into the transcript's speakers; -1 where no one is named.
    /// </summary>
    public static int[] Speakers(Transcript? transcript, double duration, int count)
    {
        var speakers = new int[Math.Max(0, count)];
        Array.Fill(speakers, -1);
        if (transcript is null || duration <= 0 || count <= 0) return speakers;
        var indices = transcript.Speakers.Select((speaker, index) => (speaker.Id, index)).ToDictionary(pair => pair.Id, pair => pair.index);
        foreach (var segment in transcript.Segments)
        {
            if (segment.SpeakerId is not { } id || !indices.TryGetValue(id, out var index)) continue;
            var first = Math.Clamp((int)(segment.StartTime / duration * count), 0, count - 1);
            var last = Math.Clamp((int)Math.Ceiling(segment.EndTime / duration * count) - 1, first, count - 1);
            for (var bar = first; bar <= last; bar++) speakers[bar] = index;
        }
        return speakers;
    }
}
