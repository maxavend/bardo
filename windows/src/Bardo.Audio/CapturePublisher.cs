using Bardo.Capture;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Bardo.Audio;

/// <summary>
/// Turns a finished or interrupted capture into a Library recording: each track is
/// compressed as Settings ask, a meeting gets its conversation mix, and everything is
/// moved into the Library in one publication. Staged WAVs stay until that succeeds.
/// </summary>
public sealed class CapturePublisher(RecordingStore store, CaptureStaging staging)
{
    /// <summary>Shorter than this, a capture holds no audio worth keeping.</summary>
    public const double MinimumDuration = 0.25;

    public async Task<Recording?> PublishAsync(CaptureManifest manifest, AudioEncoding encoding, CancellationToken cancellationToken = default)
    {
        var tracks = manifest.Tracks
            .Select(track => (Track: track, Path: staging.TrackPath(manifest, track)))
            .Where(track => File.Exists(track.Path))
            .ToList();
        foreach (var track in tracks) WaveFile.Repair(track.Path);
        tracks = [.. tracks.Where(track => WaveFile.Duration(track.Path) >= MinimumDuration)];
        if (tracks.Count == 0)
        {
            staging.Discard(manifest.RecordingId);
            return null;
        }

        var directory = staging.DirectoryFor(manifest.RecordingId);
        var assets = new List<AudioAsset>();
        var files = new Dictionary<Guid, string>();
        await Task.Run(() =>
        {
            foreach (var (track, path) in tracks)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var channels = track.Kind == CaptureTrackKind.Microphone ? 1 : 2;
                var output = AudioEncoder.Encode(path, Path.Combine(directory, track.AssetId.ToUuidString()), encoding, channels);
                assets.Add(Asset(track.AssetId, output, track.Role, $"{TrackName(track.Kind)}{Path.GetExtension(output)}"));
                files[track.AssetId] = output;
            }
            if (tracks.Count > 1)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var mixId = Guid.NewGuid();
                var output = AudioEncoder.Mix([.. tracks.Select(track => track.Path)], Path.Combine(directory, $"{mixId.ToUuidString()}.m4a"), encoding);
                assets.Add(Asset(mixId, output, AudioAssetRole.ConversationMix, "Conversation.m4a", [.. tracks.Select(track => track.Track.AssetId)]));
                files[mixId] = output;
            }
        }, cancellationToken).ConfigureAwait(false);

        var recording = new Recording(
            manifest.Title,
            manifest.Sources,
            manifest.StartedAt,
            assets.Max(asset => asset.Metadata.Duration),
            ProcessingState.Pending,
            assets.ToEquatableArray(),
            manifest.Notes,
            id: manifest.RecordingId);
        await store.ImportRecordingAsync(recording, files, transferringOwnership: true).ConfigureAwait(false);
        staging.Discard(manifest.RecordingId);
        return recording;
    }

    private static AudioAsset Asset(Guid id, string path, AudioAssetRole role, string originalFileName, EquatableArray<Guid> derivedFrom = default) =>
        new(originalFileName, Path.GetExtension(path).TrimStart('.'), new MediaFoundationMetadataReader().Read(path), role, derivedFromAssetIds: derivedFrom, id: id);

    private static string TrackName(CaptureTrackKind kind) => kind == CaptureTrackKind.Microphone ? "Microphone" : "System Audio";
}

/// <summary>Compresses staged WAVs with Windows' AAC encoder, or keeps them as 16-bit WAV.</summary>
public static class AudioEncoder
{
    /// <summary>
    /// Windows' AAC encoder takes 44.1 or 48 kHz and 96, 128, 160 or 192 kbit/s; each
    /// quality maps to the nearest it allows.
    /// </summary>
    public static (int SampleRate, int BitRate) AacSettings(AudioQualityPreset preset) => preset switch
    {
        AudioQualityPreset.Maximum => (48_000, 192_000),
        AudioQualityPreset.High => (48_000, 160_000),
        AudioQualityPreset.Balanced => (44_100, 128_000),
        _ => (44_100, 96_000),
    };

    /// <summary>Writes <paramref name="outputPathWithoutExtension"/> plus the format's extension and returns that path.</summary>
    public static string Encode(string wavPath, string outputPathWithoutExtension, AudioEncoding encoding, int channels)
    {
        using var reader = new WaveFileReader(wavPath);
        var samples = reader.ToSampleProvider();
        samples = channels == 1 ? SampleConversions.Mono(samples) : SampleConversions.Stereo(samples);
        return Write(samples, outputPathWithoutExtension, encoding);
    }

    /// <summary>The tracks played together in stereo, for listening and transcribing. Always AAC.</summary>
    public static string Mix(IReadOnlyList<string> wavPaths, string outputPath, AudioEncoding encoding)
    {
        var readers = wavPaths.Select(path => new WaveFileReader(path)).ToList();
        try
        {
            var (sampleRate, _) = AacSettings(encoding.Preset);
            var inputs = readers.Select(reader => SampleConversions.Resampled(SampleConversions.Stereo(reader.ToSampleProvider()), sampleRate));
            var mixer = new MixingSampleProvider(inputs) { ReadFully = false };
            return Write(mixer, Path.ChangeExtension(outputPath, null), encoding with { Format = AudioStorageFormat.Aac });
        }
        finally
        {
            foreach (var reader in readers) reader.Dispose();
        }
    }

    private static string Write(ISampleProvider samples, string outputPathWithoutExtension, AudioEncoding encoding)
    {
        MediaFoundation.EnsureStarted();
        var (sampleRate, bitRate) = AacSettings(encoding.Preset);
        var resampled = SampleConversions.Resampled(samples, encoding.Format == AudioStorageFormat.Aac ? sampleRate : (int)encoding.Preset.SampleRate());
        var pcm = new SampleToWaveProvider16(resampled);
        if (encoding.Format == AudioStorageFormat.Aac)
        {
            var path = outputPathWithoutExtension + ".m4a";
            MediaFoundationEncoder.EncodeToAac(pcm, path, bitRate);
            return path;
        }
        // Windows has no Apple Lossless encoder; lossless recordings are kept as WAV.
        var wavPath = outputPathWithoutExtension + ".wav";
        WaveFileWriter.CreateWaveFile(wavPath, pcm);
        return wavPath;
    }
}
