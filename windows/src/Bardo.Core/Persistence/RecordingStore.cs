using System.Text.Json;
using Bardo.Domain;
using Bardo.Serialization;

namespace Bardo.Persistence;

/// <summary>Moves a file or folder where the person can still recover it.</summary>
public interface IRecycleBin
{
    void Recycle(string path);
}

/// <summary>
/// The managed Library: one folder per recording with its manifest and audio. Calls are
/// serialized, like the macOS actor, and run off the caller's thread.
/// </summary>
public sealed class RecordingStore : IDisposable
{
    public const string ManifestFileName = "manifest.json";
    public const string AudioDirectoryName = "audio";

    private readonly string _rootPath;
    private readonly IRecycleBin? _recycleBin;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public RecordingStore(string rootPath, IRecycleBin? recycleBin = null)
    {
        _rootPath = rootPath;
        _recycleBin = recycleBin;
    }

    public static RecordingStore Live(IRecycleBin? recycleBin = null) => new(DefaultLibraryPath(), recycleBin);

    /// <summary><c>%LOCALAPPDATA%\Bardo\Library</c>: per user, never roamed.</summary>
    public static string DefaultLibraryPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create),
        "Bardo",
        "Library");

    public Task SaveAsync(Recording recording) => Run(() => Save(recording));

    public Task UpdateAsync(Recording recording) => Run(() =>
    {
        if (!File.Exists(ManifestPath(recording.Id))) throw RecordingStoreException.RecordingNotFound(recording.Id);
        Save(recording);
    });

    public Task ImportRecordingAsync(Recording recording, AudioAsset audioAsset, string sourcePath, bool transferringOwnership = false) =>
        ImportRecordingAsync(recording, new Dictionary<Guid, string> { [audioAsset.Id] = sourcePath }, transferringOwnership);

    /// <summary>Publishes a recording with its managed audio.</summary>
    /// <remarks>
    /// With <paramref name="transferringOwnership"/>, source files are moved instead of
    /// copied. Bardo uses this for its own capture staging, which lives on the same volume:
    /// publication is then instant and needs no extra disk space. If publication fails,
    /// moved files are returned to their original locations before the partial recording
    /// is removed.
    /// </remarks>
    public Task ImportRecordingAsync(
        Recording recording,
        IReadOnlyDictionary<Guid, string> audioFiles,
        bool transferringOwnership = false) => Run(() => ImportRecording(recording, audioFiles, transferringOwnership));

    /// <summary>
    /// Swaps tracks of a saved recording for new encodings of the same audio, as when
    /// compressing it. New files are copied in first; each one then takes its track's
    /// place in one move, the manifest follows, and files left under an old name are
    /// removed last.
    /// </summary>
    public Task<Recording> ReplaceAudioAsync(Guid recordingId, IReadOnlyList<(AudioAsset Asset, string SourcePath)> replacements) =>
        Run(() => ReplaceAudio(recordingId, replacements));

    /// <summary>
    /// Returns audio from a publication that never wrote its manifest (Bardo quit or
    /// crashed halfway) to the capture's staging directory, so recovery sees every source
    /// again. Returns true when an incomplete publication was reclaimed.
    /// </summary>
    public Task<bool> ReclaimIncompletePublicationAsync(Guid recordingId, string stagingDirectory) =>
        Run(() => ReclaimIncompletePublication(recordingId, stagingDirectory));

    public Task<Recording> ReadAsync(Guid id) => Run(() => Read(id));

    public Task<string> ManagedAudioPathAsync(Guid recordingId, Guid audioAssetId) => Run(() =>
    {
        var recording = Read(recordingId);
        var asset = recording.AudioAssets.FirstOrDefault(candidate => candidate.Id == audioAssetId)
            ?? throw RecordingStoreException.AudioAssetNotFound(recordingId, audioAssetId);
        var path = ManagedAudioPath(recordingId, asset);
        if (!File.Exists(path)) throw RecordingStoreException.ManagedAudioMissing(recordingId, audioAssetId);
        return path;
    });

    /// <summary>Whether anything, complete or not, already occupies this recording's folder.</summary>
    public Task<bool> RecordingDirectoryExistsAsync(Guid recordingId) =>
        Run(() => Directory.Exists(RecordingDirectory(recordingId)));

    /// <summary>
    /// UUIDs cannot introduce path traversal. Returning a path derived only from the
    /// store root keeps File Explorer actions scoped to Bardo's managed Library.
    /// </summary>
    public string RecordingDirectoryPath(Guid recordingId) => RecordingDirectory(recordingId);

    public Task<LibrarySnapshot> LoadLibraryAsync() => Run(LoadLibrary);

    public Task DeleteAsync(Guid id) => Run(() =>
    {
        var directory = RecordingDirectory(id);
        if (!Directory.Exists(directory)) throw RecordingStoreException.RecordingNotFound(id);
        try
        {
            Directory.Delete(directory, recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw RecordingStoreException.FileSystem("delete", id.ToUuidString(), error.Message, error);
        }
    });

    public Task MoveToRecycleBinAsync(Guid id) => Run(() =>
    {
        var directory = RecordingDirectory(id);
        if (!Directory.Exists(directory)) throw RecordingStoreException.RecordingNotFound(id);
        Recycle(directory, "move recording to the Recycle Bin", id.ToUuidString());
    });

    /// <summary>The file or folder a Library issue refers to, inside the managed Library only.</summary>
    public string? ItemPath(RecordingStoreIssue issue)
    {
        // Names come from listing the Library; still refuse anything that could leave it.
        if (issue.EntryName is "" or "." or ".."
            || issue.EntryName.Contains('/', StringComparison.Ordinal)
            || issue.EntryName.Contains('\\', StringComparison.Ordinal))
        {
            return null;
        }
        string? path = issue.Kind switch
        {
            RecordingStoreIssue.IssueKind.MissingManifest
                or RecordingStoreIssue.IssueKind.CorruptManifest
                or RecordingStoreIssue.IssueKind.UnsupportedSchemaVersion
                or RecordingStoreIssue.IssueKind.IdentityMismatch
                or RecordingStoreIssue.IssueKind.UnexpectedEntry
                or RecordingStoreIssue.IssueKind.UnreadableEntry => Path.Combine(_rootPath, issue.EntryName),
            RecordingStoreIssue.IssueKind.TemporaryArtifact => issue.RecordingId is { } id
                ? Path.Combine(RecordingDirectory(id), issue.EntryName)
                : null,
            RecordingStoreIssue.IssueKind.TemporaryAudioArtifact => issue.RecordingId is { } id
                ? Path.Combine(AudioDirectory(id), issue.EntryName)
                : null,
            RecordingStoreIssue.IssueKind.MissingAudioFile
                or RecordingStoreIssue.IssueKind.MissingDerivedAudioFile => issue.RecordingId is { } id
                ? RecordingDirectory(id)
                : null,
            _ => null,
        };
        return path is not null && (File.Exists(path) || Directory.Exists(path)) ? path : null;
    }

    /// <summary>
    /// Moves what a Library issue refers to into the Recycle Bin, where it can be
    /// recovered. Only issues that cannot take a loadable conversation with them.
    /// </summary>
    public Task MoveIssueItemToRecycleBinAsync(RecordingStoreIssue issue) => Run(() =>
    {
        if (!issue.CanMoveToRecycleBin || ItemPath(issue) is not { } path)
        {
            throw RecordingStoreException.FileSystem(
                "move library item to the Recycle Bin",
                issue.EntryName,
                "This item cannot be moved to the Recycle Bin from Bardo.");
        }
        Recycle(path, "move library item to the Recycle Bin", issue.EntryName);
    });

    private void Save(Recording recording)
    {
        var data = Encode(recording);
        var directory = RecordingDirectory(recording.Id);
        EnsureDirectoryExists(directory);
        AtomicallyWrite(data, ManifestPath(recording.Id));
    }

    private void ImportRecording(Recording recording, IReadOnlyDictionary<Guid, string> audioFiles, bool transferringOwnership)
    {
        var expectedIds = recording.AudioAssets.Select(asset => asset.Id).ToHashSet();
        var suppliedIds = audioFiles.Keys.ToHashSet();
        if (expectedIds.Count == 0 || !expectedIds.SetEquals(suppliedIds))
        {
            throw RecordingStoreException.AudioAssetFileSetMismatch(recording.Id, expectedIds.Count, suppliedIds.Count);
        }

        var data = Encode(recording);
        EnsureDirectoryExists(_rootPath);

        var recordingDirectory = RecordingDirectory(recording.Id);
        if (Directory.Exists(recordingDirectory)) throw RecordingStoreException.RecordingAlreadyExists(recording.Id);

        // Moved sources and where they currently are, so a failure can return them.
        var transferred = new List<(string Source, string Current)>();

        try
        {
            EnsureDirectoryExists(recordingDirectory);
            var audioDirectory = AudioDirectory(recording.Id);
            EnsureDirectoryExists(audioDirectory);

            foreach (var asset in recording.AudioAssets)
            {
                if (!audioFiles.TryGetValue(asset.Id, out var sourcePath))
                {
                    throw RecordingStoreException.AudioAssetNotFound(recording.Id, asset.Id);
                }

                var temporaryAudioPath = Path.Combine(audioDirectory, $".audio-{asset.Id.ToUuidString()}.tmp");
                var destinationAudioPath = ManagedAudioPath(recording.Id, asset);

                try
                {
                    if (transferringOwnership)
                    {
                        File.Move(sourcePath, temporaryAudioPath);
                        transferred.Add((sourcePath, temporaryAudioPath));
                    }
                    else
                    {
                        File.Copy(sourcePath, temporaryAudioPath);
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    throw RecordingStoreException.FileSystem(
                        transferringOwnership ? "move managed audio" : "copy managed audio",
                        Path.GetFileName(sourcePath),
                        error.Message,
                        error);
                }
                DurableFile.RestrictToOwner(temporaryAudioPath);

                AtomicallyMove(temporaryAudioPath, destinationAudioPath, "finalize managed audio");
                var index = transferred.FindLastIndex(file => file.Current == temporaryAudioPath);
                if (index >= 0) transferred[index] = (transferred[index].Source, destinationAudioPath);
            }

            // All managed audio files are final before the manifest becomes visible.
            AtomicallyWrite(data, ManifestPath(recording.Id));
        }
        catch
        {
            var everySourceReturned = true;
            for (var index = transferred.Count - 1; index >= 0; index--)
            {
                try
                {
                    File.Move(transferred[index].Current, transferred[index].Source);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    everySourceReturned = false;
                }
            }
            // This directory was created exclusively for this failed publication. Removing
            // it cannot affect an existing recording; transferred sources were returned
            // above. If any could not be returned, keep the directory so no audio is lost:
            // `ReclaimIncompletePublication` hands it back to recovery later.
            if (everySourceReturned) TryDeleteDirectory(recordingDirectory);
            throw;
        }
    }

    private Recording ReplaceAudio(Guid recordingId, IReadOnlyList<(AudioAsset Asset, string SourcePath)> replacements)
    {
        var recording = Read(recordingId);
        var audioDirectory = AudioDirectory(recordingId);
        var staged = new List<(AudioAsset Asset, string Path)>();
        try
        {
            foreach (var (asset, sourcePath) in replacements)
            {
                if (!recording.AudioAssets.Any(existing => existing.Id == asset.Id))
                {
                    throw RecordingStoreException.AudioAssetNotFound(recordingId, asset.Id);
                }
                var temporaryPath = Path.Combine(audioDirectory, $".audio-{asset.Id.ToUuidString()}.replacing.tmp");
                File.Delete(temporaryPath);
                File.Copy(sourcePath, temporaryPath);
                DurableFile.RestrictToOwner(temporaryPath);
                staged.Add((asset, temporaryPath));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or RecordingStoreException)
        {
            foreach (var file in staged) TryDeleteFile(file.Path);
            throw RecordingStoreException.FileSystem("copy replacement audio", recordingId.ToUuidString(), error.Message, error);
        }

        var assets = recording.AudioAssets.ToList();
        var obsolete = new List<string>();
        foreach (var (asset, temporaryPath) in staged)
        {
            var index = assets.FindIndex(existing => existing.Id == asset.Id);
            if (index < 0) continue;
            var oldPath = ManagedAudioPath(recordingId, assets[index]);
            var newPath = ManagedAudioPath(recordingId, asset);
            AtomicallyMove(temporaryPath, newPath, "replace managed audio");
            if (oldPath != newPath) obsolete.Add(oldPath);
            assets[index] = asset;
        }
        recording = recording with { AudioAssets = assets };
        Save(recording);
        foreach (var path in obsolete) TryDeleteFile(path);
        return recording;
    }

    private bool ReclaimIncompletePublication(Guid recordingId, string stagingDirectory)
    {
        var directory = RecordingDirectory(recordingId);
        if (!Directory.Exists(directory) || File.Exists(ManifestPath(recordingId))) return false;

        var audioDirectory = AudioDirectory(recordingId);
        foreach (var entry in ListEntries(audioDirectory))
        {
            var name = Path.GetFileName(entry);
            string assetName;
            string fileExtension;
            if (name.StartsWith(".audio-", StringComparison.Ordinal) && name.EndsWith(".tmp", StringComparison.Ordinal))
            {
                assetName = name[".audio-".Length..^".tmp".Length];
                fileExtension = DetectedAudioExtension(entry);
            }
            else
            {
                assetName = Path.GetFileNameWithoutExtension(name);
                fileExtension = Path.GetExtension(name).TrimStart('.');
            }
            if (!Guid.TryParseExact(assetName, "D", out _) || fileExtension.Length == 0) continue;

            var destination = Path.Combine(stagingDirectory, $"{assetName}.{fileExtension}");
            if (File.Exists(destination)) continue;
            File.Move(entry, destination);
        }

        if (ListEntries(audioDirectory).Count == 0) Directory.Delete(directory, recursive: true);
        return true;
    }

    /// <summary>Identifies a staged audio container from its header.</summary>
    private static string DetectedAudioExtension(string path)
    {
        Span<byte> header = stackalloc byte[12];
        int read;
        try
        {
            using var stream = File.OpenRead(path);
            read = stream.ReadAtLeast(header, header.Length, throwOnEndOfStream: false);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return "m4a";
        }
        var start = header[..read];
        if (start.StartsWith("caff"u8)) return "caf";
        if (start.StartsWith("RIFF"u8)) return "wav";
        if (start.StartsWith("FORM"u8)) return "aiff";
        return "m4a";
    }

    private Recording Read(Guid id)
    {
        var path = ManifestPath(id);
        if (!File.Exists(path)) throw RecordingStoreException.RecordingNotFound(id);

        byte[] data;
        try
        {
            data = File.ReadAllBytes(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw RecordingStoreException.FileSystem("read", id.ToUuidString(), error.Message, error);
        }
        var recording = Decode(data);
        if (recording.Id != id) throw RecordingStoreException.IdentityMismatch(id, recording.Id);
        return recording;
    }

    private LibrarySnapshot LoadLibrary()
    {
        EnsureDirectoryExists(_rootPath);
        // Recordings are private. Tighten folders created by earlier builds.
        DurableFile.RestrictToOwner(Path.GetDirectoryName(_rootPath)!, DurableFile.PrivateDirectoryPermissions);

        IReadOnlyList<string> entries;
        try
        {
            entries = [.. Directory.EnumerateFileSystemEntries(_rootPath).Where(entry => !IsHidden(entry))];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw RecordingStoreException.FileSystem("list", "library", error.Message, error);
        }

        var recordings = new List<Recording>();
        var issues = new List<RecordingStoreIssue>();

        foreach (var entry in entries.OrderBy(Path.GetFileName, StringComparer.Ordinal))
        {
            var name = Path.GetFileName(entry);
            bool isDirectory;
            try
            {
                isDirectory = File.GetAttributes(entry).HasFlag(FileAttributes.Directory);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                issues.Add(new(RecordingStoreIssue.IssueKind.UnreadableEntry, null, name,
                    "A library entry could not be inspected and was left untouched."));
                continue;
            }

            if (!isDirectory || !Guid.TryParseExact(name, "D", out var id))
            {
                issues.Add(new(RecordingStoreIssue.IssueKind.UnexpectedEntry, null, name,
                    "An unexpected library entry was preserved and ignored."));
                continue;
            }
            DurableFile.RestrictToOwner(entry, DurableFile.PrivateDirectoryPermissions);

            issues.AddRange(TemporaryManifestArtifactIssues(entry, id));
            issues.AddRange(TemporaryAudioArtifactIssues(entry, id));

            var manifestPath = Path.Combine(entry, ManifestFileName);
            if (!File.Exists(manifestPath))
            {
                issues.Add(new(RecordingStoreIssue.IssueKind.MissingManifest, id, id.ToUuidString(),
                    $"Recording {id.ToUuidString()} has no complete manifest and was left untouched."));
                continue;
            }

            try
            {
                var recording = Decode(File.ReadAllBytes(manifestPath));
                if (recording.Id != id)
                {
                    issues.Add(new(RecordingStoreIssue.IssueKind.IdentityMismatch, id, id.ToUuidString(),
                        "A recording manifest has a mismatched identity and was not loaded."));
                    continue;
                }
                recordings.Add(recording);
                issues.AddRange(ManagedAudioIssues(recording));
            }
            catch (RecordingStoreException error) when (error.Kind == RecordingStoreErrorKind.UnsupportedSchemaVersion)
            {
                issues.Add(new(RecordingStoreIssue.IssueKind.UnsupportedSchemaVersion, id, id.ToUuidString(),
                    $"Recording {id.ToUuidString()} uses unsupported manifest schema version {error.SchemaVersion} and was preserved."));
            }
            catch (Exception error) when (error is RecordingStoreException or IOException or UnauthorizedAccessException)
            {
                issues.Add(new(RecordingStoreIssue.IssueKind.CorruptManifest, id, id.ToUuidString(),
                    $"Recording {id.ToUuidString()} has an unreadable or incomplete manifest and was preserved."));
            }
        }

        var sorted = recordings
            .OrderByDescending(recording => recording.CreatedAt)
            .ThenBy(recording => recording.Id.ToUuidString(), StringComparer.Ordinal);
        return new LibrarySnapshot(sorted.ToEquatableArray(), issues.ToEquatableArray());
    }

    private static byte[] Encode(Recording recording)
    {
        try
        {
            return BardoJson.Serialize(RecordingManifestV3.From(recording));
        }
        catch (ArgumentException error)
        {
            // Non-finite numbers cannot be written as JSON; nothing on disk changes.
            throw RecordingStoreException.InvalidManifest(error.Message, error);
        }
    }

    private static Recording Decode(byte[] data)
    {
        RecordingManifestHeader header;
        try
        {
            header = BardoJson.Deserialize<RecordingManifestHeader>(data);
        }
        catch (JsonException error)
        {
            throw RecordingStoreException.InvalidManifest(error.Message, error);
        }

        try
        {
            return header.SchemaVersion switch
            {
                RecordingManifestV1.CurrentSchemaVersion => BardoJson.Deserialize<RecordingManifestV1>(data).ToRecording(),
                RecordingManifestV2.CurrentSchemaVersion => BardoJson.Deserialize<RecordingManifestV2>(data).ToRecording(),
                RecordingManifestV3.CurrentSchemaVersion => BardoJson.Deserialize<RecordingManifestV3>(data).ToRecording(),
                _ => throw RecordingStoreException.UnsupportedSchemaVersion(header.SchemaVersion),
            };
        }
        catch (JsonException error)
        {
            throw RecordingStoreException.InvalidManifest(error.Message, error);
        }
    }

    private string RecordingDirectory(Guid id) => Path.Combine(_rootPath, id.ToUuidString());

    private string ManifestPath(Guid id) => Path.Combine(RecordingDirectory(id), ManifestFileName);

    private string AudioDirectory(Guid id) => Path.Combine(RecordingDirectory(id), AudioDirectoryName);

    private string ManagedAudioPath(Guid recordingId, AudioAsset asset) =>
        Path.Combine(AudioDirectory(recordingId), $"{asset.Id.ToUuidString()}.{asset.FileExtension}");

    private static void EnsureDirectoryExists(string path)
    {
        try
        {
            DurableFile.CreatePrivateDirectory(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw RecordingStoreException.FileSystem("create directory for", Path.GetFileName(path), error.Message, error);
        }
    }

    /// <summary>
    /// Flushes the manifest to disk before it replaces the previous one, so a power loss
    /// leaves either the old or the new manifest, never an empty file.
    /// </summary>
    private static void AtomicallyWrite(byte[] data, string destinationPath)
    {
        try
        {
            DurableFile.Write(data, destinationPath, ".manifest");
        }
        catch (DurableFileException error)
        {
            throw RecordingStoreException.FileSystem("atomically replace manifest", Path.GetFileName(destinationPath), error.Message, error);
        }
    }

    private static void AtomicallyMove(string sourcePath, string destinationPath, string operation)
    {
        try
        {
            File.Move(sourcePath, destinationPath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw RecordingStoreException.FileSystem(operation, Path.GetFileName(destinationPath), error.Message, error);
        }
    }

    private void Recycle(string path, string operation, string entry)
    {
        if (_recycleBin is null)
        {
            throw RecordingStoreException.FileSystem(operation, entry, "No Recycle Bin is available.");
        }
        try
        {
            _recycleBin.Recycle(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw RecordingStoreException.FileSystem(operation, entry, error.Message, error);
        }
    }

    private static IEnumerable<RecordingStoreIssue> TemporaryManifestArtifactIssues(string recordingDirectory, Guid recordingId) =>
        ListEntries(recordingDirectory)
            .Select(Path.GetFileName)
            .Where(name => name!.StartsWith(".manifest-", StringComparison.Ordinal) && name.EndsWith(".tmp", StringComparison.Ordinal))
            .Select(name => new RecordingStoreIssue(RecordingStoreIssue.IssueKind.TemporaryArtifact, recordingId, name!,
                $"An incomplete manifest write was detected for recording {recordingId.ToUuidString()} and was preserved."));

    private static IEnumerable<RecordingStoreIssue> TemporaryAudioArtifactIssues(string recordingDirectory, Guid recordingId) =>
        ListEntries(Path.Combine(recordingDirectory, AudioDirectoryName))
            .Select(Path.GetFileName)
            .Where(name => name!.StartsWith(".audio-", StringComparison.Ordinal) && name.EndsWith(".tmp", StringComparison.Ordinal))
            .Select(name => new RecordingStoreIssue(RecordingStoreIssue.IssueKind.TemporaryAudioArtifact, recordingId, name!,
                $"An incomplete audio publication was detected for recording {recordingId.ToUuidString()} and was preserved."));

    private IEnumerable<RecordingStoreIssue> ManagedAudioIssues(Recording recording) =>
        recording.AudioAssets
            .Where(asset => !File.Exists(ManagedAudioPath(recording.Id, asset)))
            .Select(asset => asset.Role.IsDerived()
                ? new RecordingStoreIssue(RecordingStoreIssue.IssueKind.MissingDerivedAudioFile, recording.Id, asset.Id.ToUuidString(),
                    $"A derived playback asset for {recording.Title} is missing. Original source audio was preserved.")
                : new RecordingStoreIssue(RecordingStoreIssue.IssueKind.MissingAudioFile, recording.Id, asset.Id.ToUuidString(),
                    $"Managed source audio for {recording.Title} is missing. Its manifest was preserved."));

    internal static IReadOnlyList<string> ListEntries(string directory)
    {
        try
        {
            return Directory.Exists(directory) ? [.. Directory.EnumerateFileSystemEntries(directory)] : [];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>Dot files, as on macOS, and anything Windows marks hidden.</summary>
    private static bool IsHidden(string path)
    {
        if (Path.GetFileName(path).StartsWith('.')) return true;
        try
        {
            return OperatingSystem.IsWindows() && File.GetAttributes(path).HasFlag(FileAttributes.Hidden);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Left behind; the Library reports it.
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            Directory.Delete(path, recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Left behind; the Library reports it.
        }
    }

    public void Dispose() => _gate.Dispose();

    private async Task Run(Action work)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            await Task.Run(work).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<T> Run<T>(Func<T> work)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            return await Task.Run(work).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }
}
