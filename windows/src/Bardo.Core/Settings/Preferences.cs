using System.Text.Json;
using Bardo.Domain;
using Bardo.Library;
using Bardo.Persistence;
using Bardo.Serialization;

namespace Bardo.Settings;

/// <summary>How Bardo transcribes: Whisper large-v3 Turbo, or large-v3 in full.</summary>
public enum TranscriptionQuality
{
    /// <summary>Whisper large-v3 Turbo: fast, and what Bardo installs first.</summary>
    Balanced,

    /// <summary>Whisper large-v3 in full: slower, a little more accurate.</summary>
    Precise,
}

/// <summary>
/// What someone chose in Settings, and the favourites. On macOS these live in
/// <c>UserDefaults</c>; here, in <c>preferences.json</c> next to the Library.
/// </summary>
public sealed record Preferences
{
    public string? LocalName { get; init; }
    public EquatableArray<Guid> Favorites { get; init; }
    public LibrarySort Sort { get; init; } = LibrarySort.Newest;
    public AudioQualityPreset AudioQuality { get; init; } = AudioQualityPresetExtensions.Default;
    public AudioStorageFormat AudioFormat { get; init; } = AudioStorageFormatExtensions.Default;
    public TranscriptionTrackMode TrackMode { get; init; } = TranscriptionTrackMode.PerTrack;
    public TranscriptionQuality TranscriptionQuality { get; init; } = TranscriptionQuality.Balanced;

    /// <summary>The microphone to record from; none means the one Windows uses for calls.</summary>
    public string? MicrophoneDeviceId { get; init; }

    /// <summary>Whether first-run setup was finished or set aside; it is offered only once.</summary>
    public bool HasFinishedSetup { get; init; }

    [System.Text.Json.Serialization.JsonIgnore]
    public AudioEncoding Encoding => new(AudioQuality, AudioFormat);

    public bool IsFavorite(Guid recordingId) => Favorites.Contains(recordingId);

    public Preferences TogglingFavorite(Guid recordingId) => this with
    {
        Favorites = IsFavorite(recordingId)
            ? Favorites.Where(id => id != recordingId).ToEquatableArray()
            : [.. Favorites, recordingId],
    };
}

/// <summary>Reads and writes <see cref="Preferences"/>; a missing or unreadable file means the defaults.</summary>
public sealed class PreferencesStore
{
    public const string FileName = "preferences.json";

    private readonly string _path;
    private readonly Lock _gate = new();
    private Preferences? _current;

    public PreferencesStore(string directory)
    {
        _path = Path.Combine(directory, FileName);
    }

    /// <summary><c>%LOCALAPPDATA%\Bardo\preferences.json</c>, beside the Library folder.</summary>
    public static PreferencesStore Live() =>
        new(Path.GetDirectoryName(RecordingStore.DefaultLibraryPath())!);

    public Preferences Current
    {
        get
        {
            lock (_gate)
            {
                return _current ??= Read();
            }
        }
    }

    public event EventHandler<Preferences>? Changed;

    public void Update(Func<Preferences, Preferences> change)
    {
        Preferences updated;
        lock (_gate)
        {
            updated = change(_current ??= Read());
            if (updated == _current) return;
            DurableFile.CreatePrivateDirectory(Path.GetDirectoryName(_path)!);
            DurableFile.Write(BardoJson.Serialize(updated), _path, ".preferences");
            _current = updated;
        }
        Changed?.Invoke(this, updated);
    }

    private Preferences Read()
    {
        try
        {
            return File.Exists(_path) ? BardoJson.Deserialize<Preferences>(File.ReadAllBytes(_path)) : new Preferences();
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            return new Preferences();
        }
    }
}
