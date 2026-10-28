using System.Runtime.CompilerServices;
using Bardo.Library;

namespace Bardo.Capture;

/// <summary>
/// Decodes WAV files on any platform, resampling linearly. Windows decodes everything
/// with Media Foundation; this one lets the recognisers run in tests and on a Mac.
/// </summary>
public sealed class WaveDecoder : IAudioDecoder
{
    public async IAsyncEnumerable<float[]> ReadMonoAsync(
        string path,
        int sampleRate,
        TimeSpan chunkLength,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var samples = await Task.Run(() => Resample(WaveFile.ReadMonoSamples(path, out var rate), rate, sampleRate), cancellationToken).ConfigureAwait(false);
        var chunk = Math.Max(1, (int)(sampleRate * chunkLength.TotalSeconds));
        for (var start = 0; start < samples.Length; start += chunk)
        {
            cancellationToken.ThrowIfCancellationRequested();
            yield return samples[start..Math.Min(samples.Length, start + chunk)];
        }
    }

    public static float[] Resample(float[] samples, int from, int to)
    {
        if (from == to || samples.Length == 0) return samples;
        var output = new float[(int)((long)samples.Length * to / from)];
        var step = (double)from / to;
        for (var index = 0; index < output.Length; index++)
        {
            var position = index * step;
            var left = (int)position;
            var right = Math.Min(left + 1, samples.Length - 1);
            var fraction = (float)(position - left);
            output[index] = samples[left] + (samples[right] - samples[left]) * fraction;
        }
        return output;
    }
}
