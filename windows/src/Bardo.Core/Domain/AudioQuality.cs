namespace Bardo.Domain;

/// <summary>
/// How much detail Bardo keeps of each recording. Every level keeps voices perfectly
/// clear and transcribes the same: transcription listens at 16 kHz, and even the
/// compact level records well above that.
/// </summary>
public enum AudioQualityPreset
{
    Maximum,
    High,
    Balanced,
    Compact,
}

/// <summary>
/// The file format a recording is kept in. AAC sounds better than MP3 at the same size
/// and opens everywhere.
/// </summary>
public enum AudioStorageFormat
{
    Aac,
    Alac,
    Wav,
}

public static class AudioQualityPresetExtensions
{
    public const AudioQualityPreset Default = AudioQualityPreset.Balanced;

    public static double SampleRate(this AudioQualityPreset preset) => preset switch
    {
        AudioQualityPreset.Maximum or AudioQualityPreset.High => 48_000,
        AudioQualityPreset.Balanced => 32_000,
        AudioQualityPreset.Compact => 24_000,
        _ => throw new ArgumentOutOfRangeException(nameof(preset)),
    };

    /// <summary>
    /// AAC bit rate for a track; stereo gets more, but not twice, as its channels share
    /// most of what they carry.
    /// </summary>
    public static int AacBitRate(this AudioQualityPreset preset, int channels)
    {
        var stereo = channels > 1;
        return preset switch
        {
            AudioQualityPreset.Maximum => stereo ? 256_000 : 160_000,
            AudioQualityPreset.High => stereo ? 160_000 : 96_000,
            AudioQualityPreset.Balanced => stereo ? 96_000 : 64_000,
            AudioQualityPreset.Compact => stereo ? 64_000 : 40_000,
            _ => throw new ArgumentOutOfRangeException(nameof(preset)),
        };
    }
}

public static class AudioStorageFormatExtensions
{
    public const AudioStorageFormat Default = AudioStorageFormat.Aac;

    public static string FileExtension(this AudioStorageFormat format) => format switch
    {
        AudioStorageFormat.Aac or AudioStorageFormat.Alac => "m4a",
        AudioStorageFormat.Wav => "wav",
        _ => throw new ArgumentOutOfRangeException(nameof(format)),
    };

    public static bool IsLossless(this AudioStorageFormat format) => format != AudioStorageFormat.Aac;
}

/// <summary>A quality and a format together: what files Bardo writes, and how much they weigh.</summary>
public sealed record AudioEncoding(AudioQualityPreset Preset, AudioStorageFormat Format)
{
    public static AudioEncoding Default { get; } = new(AudioQualityPresetExtensions.Default, AudioStorageFormatExtensions.Default);

    /// <summary>Lossless audio keeps 16 bits per sample: far more than a voice needs.</summary>
    public const int LosslessBitDepth = 16;

    /// <summary>Apple Lossless keeps roughly this share of the uncompressed size for speech.</summary>
    public const double LosslessShare = 0.55;

    public string FileExtension => Format.FileExtension();

    /// <summary>About how many bytes a minute of one track takes.</summary>
    public double BytesPerMinute(int channels)
    {
        if (Format == AudioStorageFormat.Aac) return Preset.AacBitRate(channels) / 8.0 * 60;
        var uncompressed = Preset.SampleRate() * (LosslessBitDepth / 8) * channels * 60;
        return Format == AudioStorageFormat.Alac ? uncompressed * LosslessShare : uncompressed;
    }

    /// <summary>A meeting keeps your microphone, the computer's audio and their mix.</summary>
    public double MeetingBytesPerMinute =>
        BytesPerMinute(channels: 1)
        + BytesPerMinute(channels: 2)
        + (this with { Format = AudioStorageFormat.Aac }).BytesPerMinute(channels: 2);
}
