using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;

namespace Bardo.Capture;

/// <summary>Which track of a capture a file holds.</summary>
public enum CaptureTrackKind
{
    Microphone,
    SystemAudio,
}

public sealed record CaptureTrack(Guid AssetId, CaptureTrackKind Kind, string FileName)
{
    public AudioAssetRole Role => Kind == CaptureTrackKind.Microphone ? AudioAssetRole.MicrophoneOriginal : AudioAssetRole.SystemOriginal;
}

/// <summary>
/// What a capture in progress is, written beside its audio as <c>capture.json</c> when it
/// starts and whenever notes change. After a crash it is what lets the recording come
/// back with its title, date, sources and notes.
/// </summary>
public sealed record CaptureManifest(
    Guid RecordingId,
    string Title,
    DateTimeOffset StartedAt,
    EquatableArray<CaptureTrack> Tracks,
    RecordingNotes Notes)
{
    public const string FileName = "capture.json";

    public EquatableArray<AudioSource> Sources => Tracks
        .Select(track => track.Kind == CaptureTrackKind.Microphone ? AudioSource.Microphone : AudioSource.SystemAudio)
        .Distinct()
        .ToEquatableArray();
}

/// <summary>
/// Where captures are staged until they are published to the Library: one folder per
/// capture under <c>%LOCALAPPDATA%\Bardo\Captures</c>, on the same volume, so publishing
/// moves files instead of copying them.
/// </summary>
public sealed class CaptureStaging(string rootPath)
{
    public string RootPath { get; } = rootPath;

    public static CaptureStaging Live() =>
        new(Path.Combine(Path.GetDirectoryName(RecordingStore.DefaultLibraryPath())!, "Captures"));

    public string DirectoryFor(Guid recordingId) => Path.Combine(RootPath, recordingId.ToUuidString());

    public string TrackPath(CaptureManifest manifest, CaptureTrack track) =>
        Path.Combine(DirectoryFor(manifest.RecordingId), track.FileName);

    public CaptureManifest Begin(string title, IReadOnlyList<CaptureTrackKind> kinds, DateTimeOffset startedAt)
    {
        var recordingId = Guid.NewGuid();
        var tracks = kinds.Select(kind =>
        {
            var assetId = Guid.NewGuid();
            return new CaptureTrack(assetId, kind, $"{assetId.ToUuidString()}.wav");
        }).ToEquatableArray();
        var manifest = new CaptureManifest(recordingId, title, BardoTime.Normalize(startedAt), tracks, RecordingNotes.Empty);
        DurableFile.CreatePrivateDirectory(DirectoryFor(recordingId));
        Save(manifest);
        return manifest;
    }

    public void Save(CaptureManifest manifest) =>
        DurableFile.Write(BardoJson.Serialize(manifest), Path.Combine(DirectoryFor(manifest.RecordingId), CaptureManifest.FileName), ".capture");

    /// <summary>Captures that never finished, oldest first: what a crash or a forced quit left behind.</summary>
    public IReadOnlyList<CaptureManifest> Interrupted()
    {
        if (!Directory.Exists(RootPath)) return [];
        var manifests = new List<CaptureManifest>();
        foreach (var directory in Directory.EnumerateDirectories(RootPath))
        {
            var path = Path.Combine(directory, CaptureManifest.FileName);
            try
            {
                if (!File.Exists(path)) continue;
                var manifest = BardoJson.Deserialize<CaptureManifest>(File.ReadAllBytes(path));
                if (manifest.Tracks.Any(track => File.Exists(TrackPath(manifest, track)))) manifests.Add(manifest);
            }
            catch (Exception error) when (error is System.Text.Json.JsonException or IOException or UnauthorizedAccessException)
            {
                // Left in place; nothing Bardo can recover from it.
            }
        }
        return [.. manifests.OrderBy(manifest => manifest.StartedAt)];
    }

    /// <summary>Removes a capture's folder once its recording is in the Library, or when it holds no audio.</summary>
    public void Discard(Guid recordingId)
    {
        var directory = DirectoryFor(recordingId);
        if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
    }
}
