using System.Text.Json;
using Bardo.Domain;
using Bardo.Resources;
using Bardo.Serialization;

namespace Bardo.Persistence;

internal sealed record TranscriptDocumentV1(int SchemaVersion, Transcript Transcript)
{
    public const int CurrentSchemaVersion = 1;

    public static TranscriptDocumentV1 For(Transcript transcript) => new(CurrentSchemaVersion, transcript);
}

internal sealed record TranscriptDocumentHeader(int SchemaVersion);

public enum TranscriptStoreErrorKind
{
    RecordingNotFound,
    TranscriptNotFound,
    UnsupportedSchemaVersion,
    InvalidTranscript,
    IdentityMismatch,
    FileSystem,
}

public sealed class TranscriptStoreException : Exception
{
    private TranscriptStoreException(TranscriptStoreErrorKind kind, string message, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
    }

    public TranscriptStoreErrorKind Kind { get; }
    public Guid? RecordingId { get; private init; }
    public int? SchemaVersion { get; private init; }

    public static TranscriptStoreException RecordingNotFound(Guid id) =>
        new(TranscriptStoreErrorKind.RecordingNotFound, Strings.RecordingNotFound(id.ToUuidString())) { RecordingId = id };

    public static TranscriptStoreException TranscriptNotFound(Guid id) =>
        new(TranscriptStoreErrorKind.TranscriptNotFound, Strings.TranscriptNotFound(id.ToUuidString())) { RecordingId = id };

    public static TranscriptStoreException UnsupportedSchemaVersion(int version) =>
        new(TranscriptStoreErrorKind.UnsupportedSchemaVersion, Strings.TranscriptUnsupportedSchema(version)) { SchemaVersion = version };

    public static TranscriptStoreException InvalidTranscript(string description, Exception? inner = null) =>
        new(TranscriptStoreErrorKind.InvalidTranscript, Strings.TranscriptInvalid(description), inner);

    public static TranscriptStoreException IdentityMismatch(Guid expected, Guid actual) =>
        new(TranscriptStoreErrorKind.IdentityMismatch, Strings.TranscriptIdentityMismatch(expected.ToUuidString(), actual.ToUuidString()))
        {
            RecordingId = expected,
        };

    public static TranscriptStoreException FileSystem(string operation, string entry, string description, Exception? inner = null) =>
        new(TranscriptStoreErrorKind.FileSystem, Strings.CouldNotOperate(operation, entry, description), inner);
}

/// <summary>Each recording's <c>transcript.json</c>, next to its manifest.</summary>
public sealed class TranscriptStore : IDisposable
{
    public const string TranscriptFileName = "transcript.json";

    private readonly string _rootPath;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public TranscriptStore(string rootPath)
    {
        _rootPath = rootPath;
    }

    public static TranscriptStore Live() => new(RecordingStore.DefaultLibraryPath());

    public Task SaveAsync(Transcript transcript) => Run(() =>
    {
        var recordingDirectory = Path.Combine(_rootPath, transcript.RecordingId.ToUuidString());
        if (!File.Exists(Path.Combine(recordingDirectory, RecordingStore.ManifestFileName)))
        {
            throw TranscriptStoreException.RecordingNotFound(transcript.RecordingId);
        }

        byte[] data;
        try
        {
            data = BardoJson.Serialize(TranscriptDocumentV1.For(transcript));
        }
        catch (ArgumentException error)
        {
            // Non-finite numbers cannot be written as JSON; nothing on disk changes.
            throw TranscriptStoreException.InvalidTranscript(error.Message, error);
        }

        try
        {
            // Flushed before it replaces the previous transcript, and private to the user.
            DurableFile.Write(data, Path.Combine(recordingDirectory, TranscriptFileName), ".transcript");
        }
        catch (DurableFileException error)
        {
            throw TranscriptStoreException.FileSystem("write transcript", transcript.RecordingId.ToUuidString(), error.Message, error);
        }
        return true;
    });

    public Task<Transcript?> ReadAsync(Guid recordingId) => Run(() => Read(recordingId));

    public Task<IReadOnlyList<string>> TemporaryArtifactsAsync(Guid recordingId) => Run(() =>
        (IReadOnlyList<string>)[.. RecordingStore.ListEntries(Path.Combine(_rootPath, recordingId.ToUuidString()))
            .Where(path =>
            {
                var name = Path.GetFileName(path);
                return name.StartsWith(".transcript-", StringComparison.Ordinal) && name.EndsWith(".tmp", StringComparison.Ordinal);
            })]);

    private Transcript? Read(Guid recordingId)
    {
        var path = TranscriptPath(recordingId);
        if (!File.Exists(path)) return null;

        byte[] data;
        try
        {
            data = File.ReadAllBytes(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw TranscriptStoreException.FileSystem("read transcript", recordingId.ToUuidString(), error.Message, error);
        }

        TranscriptDocumentHeader header;
        try
        {
            header = BardoJson.Deserialize<TranscriptDocumentHeader>(data);
        }
        catch (JsonException error)
        {
            throw TranscriptStoreException.InvalidTranscript(error.Message, error);
        }
        if (header.SchemaVersion != TranscriptDocumentV1.CurrentSchemaVersion)
        {
            throw TranscriptStoreException.UnsupportedSchemaVersion(header.SchemaVersion);
        }

        TranscriptDocumentV1 document;
        try
        {
            document = BardoJson.Deserialize<TranscriptDocumentV1>(data);
        }
        catch (JsonException error)
        {
            throw TranscriptStoreException.InvalidTranscript(error.Message, error);
        }
        if (document.Transcript.RecordingId != recordingId)
        {
            throw TranscriptStoreException.IdentityMismatch(recordingId, document.Transcript.RecordingId);
        }
        return document.Transcript;
    }

    private string TranscriptPath(Guid recordingId) =>
        Path.Combine(_rootPath, recordingId.ToUuidString(), TranscriptFileName);

    public void Dispose() => _gate.Dispose();

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
