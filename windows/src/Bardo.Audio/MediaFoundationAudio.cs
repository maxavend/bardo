using System.Runtime.CompilerServices;
using Bardo.Domain;
using Bardo.Library;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Bardo.Audio;

/// <summary>Reads an audio file's length and format with Windows' own decoders (Media Foundation).</summary>
public sealed class MediaFoundationMetadataReader : IAudioMetadataReader
{
    public AudioMetadata Read(string path)
    {
        MediaFoundation.EnsureStarted();
        try
        {
            using var reader = new MediaFoundationReader(path);
            var format = reader.WaveFormat;
            var duration = reader.TotalTime.TotalSeconds;
            if (!double.IsFinite(duration) || duration <= 0 || format.SampleRate <= 0 || format.Channels <= 0)
            {
                throw AudioImportException.Unreadable();
            }
            return new AudioMetadata(duration, CodecName(path), format.SampleRate, (uint)format.Channels);
        }
        catch (Exception error) when (error is not AudioImportException)
        {
            throw AudioImportException.Unreadable(error);
        }
    }

    /// <summary>The codec as the macOS app names it, from the container Bardo reads.</summary>
    internal static string CodecName(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".m4a" or ".aac" => "AAC",
        ".mp3" => "MP3",
        ".wav" or ".aiff" => "Linear PCM",
        ".flac" => "FLAC",
        ".wma" => "WMA",
        _ => "Unknown",
    };
}

/// <summary>Decodes any file Windows can play to mono samples at the rate a recogniser needs.</summary>
public sealed class MediaFoundationDecoder : IAudioDecoder
{
    public async IAsyncEnumerable<float[]> ReadMonoAsync(
        string path,
        int sampleRate,
        TimeSpan chunkLength,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        MediaFoundation.EnsureStarted();
        using var reader = new MediaFoundationReader(path);
        var samples = SampleConversions.Resampled(SampleConversions.Mono(reader.ToSampleProvider()), sampleRate);
        var buffer = new float[Math.Max(1, (int)(sampleRate * chunkLength.TotalSeconds))];
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var filled = await Task.Run(() => SampleConversions.Fill(samples, buffer), cancellationToken).ConfigureAwait(false);
            if (filled == 0) yield break;
            yield return buffer[..filled];
            if (filled < buffer.Length) yield break;
        }
    }
}

internal static class MediaFoundation
{
    private static readonly Lazy<bool> Started = new(() =>
    {
        MediaFoundationApi.Startup();
        return true;
    });

    public static void EnsureStarted() => _ = Started.Value;
}

internal static class SampleConversions
{
    public static ISampleProvider Mono(ISampleProvider source) =>
        source.WaveFormat.Channels == 1 ? source : new DownmixSampleProvider(source);

    public static ISampleProvider Resampled(ISampleProvider source, int sampleRate) =>
        source.WaveFormat.SampleRate == sampleRate ? source : new WdlResamplingSampleProvider(source, sampleRate);

    /// <summary>Mono becomes two identical channels; anything wider is mixed down to stereo.</summary>
    public static ISampleProvider Stereo(ISampleProvider source) => source.WaveFormat.Channels switch
    {
        1 => new MonoToStereoSampleProvider(source),
        2 => source,
        _ => new MonoToStereoSampleProvider(new DownmixSampleProvider(source)),
    };

    public static int Fill(ISampleProvider source, float[] buffer)
    {
        var filled = 0;
        while (filled < buffer.Length)
        {
            var read = source.Read(buffer, filled, buffer.Length - filled);
            if (read == 0) break;
            filled += read;
        }
        return filled;
    }

    /// <summary>Averages every channel into one.</summary>
    private sealed class DownmixSampleProvider(ISampleProvider source) : ISampleProvider
    {
        private readonly int _channels = source.WaveFormat.Channels;
        private float[] _buffer = [];

        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);

        public int Read(float[] buffer, int offset, int count)
        {
            var needed = count * _channels;
            if (_buffer.Length < needed) _buffer = new float[needed];
            var read = source.Read(_buffer, 0, needed);
            var frames = read / _channels;
            for (var frame = 0; frame < frames; frame++)
            {
                float sum = 0;
                for (var channel = 0; channel < _channels; channel++) sum += _buffer[frame * _channels + channel];
                buffer[offset + frame] = sum / _channels;
            }
            return frames;
        }
    }
}
