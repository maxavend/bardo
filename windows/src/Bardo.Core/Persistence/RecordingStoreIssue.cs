using System.Text.Json;
using Bardo.Domain;
using Bardo.Resources;
using Bardo.Serialization;

namespace Bardo.Persistence;

public sealed record RecordingStoreIssue(
    RecordingStoreIssue.IssueKind Kind,
    Guid? RecordingId,
    string EntryName,
    string Message)
{
    public enum IssueKind
    {
        CorruptManifest,
        MissingManifest,
        UnsupportedSchemaVersion,
        IdentityMismatch,
        TemporaryArtifact,
        TemporaryAudioArtifact,
        MissingAudioFile,
        MissingDerivedAudioFile,
        UnexpectedEntry,
        UnreadableEntry,
    }

    public string Id =>
        $"{EntryName}|{JsonNamingPolicy.CamelCase.ConvertName(Kind.ToString())}|{RecordingId?.ToUuidString() ?? "none"}";

    /// <summary>
    /// Whether the flagged item can go to the Recycle Bin without losing a conversation
    /// that still loads: folders Bardo cannot read as a conversation, unknown entries, and
    /// leftovers of interrupted writes. Data from a newer Bardo, missing audio and
    /// inconsistent conversations are only shown in File Explorer.
    /// </summary>
    public bool CanMoveToRecycleBin => Kind switch
    {
        IssueKind.MissingManifest or IssueKind.CorruptManifest or IssueKind.UnexpectedEntry
            or IssueKind.TemporaryArtifact or IssueKind.TemporaryAudioArtifact => true,
        _ => false,
    };
}

public sealed record LibrarySnapshot(EquatableArray<Recording> Recordings, EquatableArray<RecordingStoreIssue> Issues);

public enum RecordingStoreErrorKind
{
    RecordingNotFound,
    RecordingAlreadyExists,
    AudioAssetNotFound,
    AudioAssetFileSetMismatch,
    ManagedAudioMissing,
    UnsupportedSchemaVersion,
    InvalidManifest,
    IdentityMismatch,
    FileSystem,
}

public sealed class RecordingStoreException : Exception
{
    private RecordingStoreException(RecordingStoreErrorKind kind, string message, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
    }

    public RecordingStoreErrorKind Kind { get; }
    public Guid? RecordingId { get; private init; }
    public Guid? AudioAssetId { get; private init; }
    public int? SchemaVersion { get; private init; }

    public static RecordingStoreException RecordingNotFound(Guid id) =>
        new(RecordingStoreErrorKind.RecordingNotFound, Strings.RecordingNotFound(id.ToUuidString())) { RecordingId = id };

    public static RecordingStoreException RecordingAlreadyExists(Guid id) =>
        new(RecordingStoreErrorKind.RecordingAlreadyExists, Strings.RecordingAlreadyExists(id.ToUuidString())) { RecordingId = id };

    public static RecordingStoreException AudioAssetNotFound(Guid recordingId, Guid audioAssetId) =>
        new(RecordingStoreErrorKind.AudioAssetNotFound, Strings.AudioAssetNotFound(recordingId.ToUuidString(), audioAssetId.ToUuidString()))
        {
            RecordingId = recordingId,
            AudioAssetId = audioAssetId,
        };

    public static RecordingStoreException AudioAssetFileSetMismatch(Guid recordingId, int expected, int supplied) =>
        new(RecordingStoreErrorKind.AudioAssetFileSetMismatch, Strings.AudioAssetFileSetMismatch(recordingId.ToUuidString(), expected, supplied))
        {
            RecordingId = recordingId,
        };

    public static RecordingStoreException ManagedAudioMissing(Guid recordingId, Guid audioAssetId) =>
        new(RecordingStoreErrorKind.ManagedAudioMissing, Strings.ManagedAudioMissing(recordingId.ToUuidString(), audioAssetId.ToUuidString()))
        {
            RecordingId = recordingId,
            AudioAssetId = audioAssetId,
        };

    public static RecordingStoreException UnsupportedSchemaVersion(int version) =>
        new(RecordingStoreErrorKind.UnsupportedSchemaVersion, Strings.ManifestUnsupportedSchema(version)) { SchemaVersion = version };

    public static RecordingStoreException InvalidManifest(string description, Exception? inner = null) =>
        new(RecordingStoreErrorKind.InvalidManifest, Strings.ManifestInvalid(description), inner);

    public static RecordingStoreException IdentityMismatch(Guid expected, Guid actual) =>
        new(RecordingStoreErrorKind.IdentityMismatch, Strings.ManifestIdentityMismatch(expected.ToUuidString(), actual.ToUuidString()))
        {
            RecordingId = expected,
        };

    public static RecordingStoreException FileSystem(string operation, string entry, string description, Exception? inner = null) =>
        new(RecordingStoreErrorKind.FileSystem, Strings.CouldNotOperate(operation, entry, description), inner);
}
