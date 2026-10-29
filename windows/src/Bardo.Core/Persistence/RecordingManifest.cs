using System.Text.Json;
using System.Text.Json.Serialization;
using Bardo.Domain;
using Bardo.Serialization;

namespace Bardo.Persistence;

internal sealed record RecordingManifestHeader(int SchemaVersion);

internal sealed record RecordingManifestV1(
    int SchemaVersion,
    Guid Id,
    string Title,
    double CreatedAtEpochSeconds,
    EquatableArray<AudioSource> Sources,
    ProcessingState ProcessingState,
    double? Duration = null)
{
    public const int CurrentSchemaVersion = 1;

    public Recording ToRecording() => new(
        Title,
        Sources,
        BardoTime.FromSecondsSince1970(CreatedAtEpochSeconds),
        Duration,
        ProcessingState,
        id: Id);
}

internal sealed record RecordingManifestV2(
    int SchemaVersion,
    Guid Id,
    string Title,
    double CreatedAtEpochSeconds,
    ulong CreatedAtEpochSecondsBitPattern,
    EquatableArray<AudioSource> Sources,
    ProcessingState ProcessingState,
    EquatableArray<RecordingManifestV2.AudioAssetRecord> AudioAssets,
    double? Duration = null)
{
    public const int CurrentSchemaVersion = 2;

    internal sealed record AudioAssetRecord(
        Guid Id,
        string OriginalFileName,
        string FileExtension,
        double Duration,
        string Codec,
        double SampleRate,
        uint ChannelCount)
    {
        public AudioAsset ToAsset(IReadOnlyCollection<AudioSource> sources) => new(
            OriginalFileName,
            FileExtension,
            new AudioMetadata(Duration, Codec, SampleRate, ChannelCount),
            InferredRole(sources),
            id: Id);

        private static AudioAssetRole InferredRole(IReadOnlyCollection<AudioSource> sources) =>
            sources.Distinct().ToList() switch
            {
                [AudioSource.Microphone] => AudioAssetRole.MicrophoneOriginal,
                [AudioSource.SystemAudio] => AudioAssetRole.SystemOriginal,
                _ => AudioAssetRole.ImportedOriginal,
            };
    }

    public Recording ToRecording() => new(
        Title,
        Sources,
        BardoTime.FromSecondsSince1970(BitConverter.UInt64BitsToDouble(CreatedAtEpochSecondsBitPattern)),
        Duration,
        ProcessingState,
        AudioAssets.Select(asset => asset.ToAsset(Sources)).ToEquatableArray(),
        id: Id);
}

internal sealed record RecordingManifestV3
{
    public const int CurrentSchemaVersion = 3;

    internal sealed record AudioAssetRecord(
        Guid Id,
        string OriginalFileName,
        string FileExtension,
        double Duration,
        string Codec,
        double SampleRate,
        uint ChannelCount,
        AudioAssetRole Role,
        double TimelineOffset,
        [property: JsonPropertyName("derivedFromAssetIDs")] EquatableArray<Guid> DerivedFromAssetIds)
    {
        public static AudioAssetRecord From(AudioAsset asset) => new(
            asset.Id,
            asset.OriginalFileName,
            asset.FileExtension,
            asset.Metadata.Duration,
            asset.Metadata.Codec,
            asset.Metadata.SampleRate,
            asset.Metadata.ChannelCount,
            asset.Role,
            asset.TimelineOffset,
            asset.DerivedFromAssetIds);

        public AudioAsset ToAsset() => new(
            OriginalFileName,
            FileExtension,
            new AudioMetadata(Duration, Codec, SampleRate, ChannelCount),
            Role,
            TimelineOffset,
            DerivedFromAssetIds,
            Id);
    }

    [JsonConstructor]
    public RecordingManifestV3(
        int schemaVersion,
        Guid id,
        string title,
        double createdAtEpochSeconds,
        ulong createdAtEpochSecondsBitPattern,
        EquatableArray<AudioSource> sources,
        ProcessingState processingState,
        EquatableArray<AudioAssetRecord> audioAssets,
        double? duration = null,
        RecordingNotes? notes = null,
        bool? skipsSilences = null)
    {
        SchemaVersion = schemaVersion;
        Id = id;
        Title = title;
        CreatedAtEpochSeconds = createdAtEpochSeconds;
        CreatedAtEpochSecondsBitPattern = createdAtEpochSecondsBitPattern;
        Duration = duration;
        Sources = sources;
        ProcessingState = processingState;
        AudioAssets = audioAssets;
        Notes = notes;
        SkipsSilences = skipsSilences;
    }

    public static RecordingManifestV3 From(Recording recording)
    {
        var seconds = BardoTime.ToSecondsSince1970(recording.CreatedAt);
        return new(
            CurrentSchemaVersion,
            recording.Id,
            recording.Title,
            seconds,
            BitConverter.DoubleToUInt64Bits(seconds),
            // In the order macOS writes them: by their names.
            recording.Sources.OrderBy(source => JsonNamingPolicy.CamelCase.ConvertName(source.ToString()), StringComparer.Ordinal).ToEquatableArray(),
            recording.ProcessingState,
            recording.AudioAssets.Select(AudioAssetRecord.From).ToEquatableArray(),
            recording.Duration,
            recording.Notes.IsEmpty ? null : recording.Notes,
            recording.SkipsSilences ? true : null);
    }

    public int SchemaVersion { get; }
    public Guid Id { get; }
    public string Title { get; }
    public double CreatedAtEpochSeconds { get; }
    public ulong CreatedAtEpochSecondsBitPattern { get; }
    public double? Duration { get; }
    public EquatableArray<AudioSource> Sources { get; }
    public ProcessingState ProcessingState { get; }
    public EquatableArray<AudioAssetRecord> AudioAssets { get; }

    /// <summary>
    /// Moments and sections. Absent when there are none, so older manifests read the
    /// same and older versions of Bardo ignore it.
    /// </summary>
    public RecordingNotes? Notes { get; }

    /// <summary>Present only when playback skips silences.</summary>
    public bool? SkipsSilences { get; }

    public Recording ToRecording() => new(
        Title,
        Sources,
        BardoTime.FromSecondsSince1970(BitConverter.UInt64BitsToDouble(CreatedAtEpochSecondsBitPattern)),
        Duration,
        ProcessingState,
        AudioAssets.Select(asset => asset.ToAsset()).ToEquatableArray(),
        Notes,
        SkipsSilences ?? false,
        Id);
}
