using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Resources;

namespace Bardo.Library;

/// <summary>Reads an audio file's duration, codec and format; implemented with the platform's decoders.</summary>
public interface IAudioMetadataReader
{
    /// <exception cref="AudioImportException">The file has no readable audio stream.</exception>
    AudioMetadata Read(string path);
}

public sealed class AudioImportException(string message, Exception? inner = null) : Exception(message, inner)
{
    /// <summary>The file has no audio stream Bardo can read.</summary>
    public static AudioImportException Unreadable(Exception? inner = null) => new(Strings.UnreadableAudio, inner);
}

/// <summary>Copies an audio file into the Library as a new conversation.</summary>
public sealed class AudioImporter(RecordingStore store, IAudioMetadataReader metadataReader)
{
    public static IReadOnlySet<string> SupportedFileExtensions { get; } =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "m4a", "mp3", "wav", "flac", "aac", "aiff", "wma" };

    public async Task<Recording> ImportAsync(string sourcePath)
    {
        var fileExtension = Path.GetExtension(sourcePath).TrimStart('.').ToLowerInvariant();
        if (!SupportedFileExtensions.Contains(fileExtension))
        {
            throw new AudioImportException(Strings.UnsupportedAudioFormat(fileExtension.Length == 0 ? "unknown" : $".{fileExtension}"));
        }

        var metadata = await Task.Run(() => metadataReader.Read(sourcePath)).ConfigureAwait(false);
        if (!double.IsFinite(metadata.Duration) || metadata.Duration <= 0 || metadata.SampleRate <= 0 || metadata.ChannelCount == 0)
        {
            throw new AudioImportException(Strings.UnreadableAudio);
        }

        var asset = new AudioAsset(Path.GetFileName(sourcePath), fileExtension, metadata, AudioAssetRole.ImportedOriginal);
        var title = Path.GetFileNameWithoutExtension(sourcePath);
        var recording = new Recording(
            title.Length == 0 ? Strings.ImportedAudio : title,
            [AudioSource.ImportedFile],
            duration: metadata.Duration,
            audioAssets: [asset]);

        await store.ImportRecordingAsync(recording, asset, sourcePath).ConfigureAwait(false);
        return recording;
    }
}
