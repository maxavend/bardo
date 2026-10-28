using Bardo.Serialization;

namespace Bardo.Domain;

public enum AudioSource
{
    Microphone,
    SystemAudio,
    ImportedFile,
}

public enum ProcessingState
{
    Pending,
    Processing,
    Completed,
    Failed,
}

public sealed record Recording
{
    public Recording(
        string title,
        IEnumerable<AudioSource> sources,
        DateTimeOffset? createdAt = null,
        double? duration = null,
        ProcessingState processingState = ProcessingState.Pending,
        EquatableArray<AudioAsset> audioAssets = default,
        RecordingNotes? notes = null,
        bool skipsSilences = false,
        Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Title = title;
        CreatedAt = BardoTime.Normalize(createdAt ?? DateTimeOffset.UtcNow);
        Duration = duration;
        Sources = NormalizedSources(sources);
        ProcessingState = processingState;
        AudioAssets = audioAssets;
        Notes = notes ?? RecordingNotes.Empty;
        SkipsSilences = skipsSilences;
    }

    public Guid Id { get; }
    public string Title { get; init; }
    public DateTimeOffset CreatedAt { get; }
    public double? Duration { get; init; }

    /// <summary>A set, kept in one order so recordings compare by value.</summary>
    public EquatableArray<AudioSource> Sources { get; init => field = NormalizedSources(value); }

    public ProcessingState ProcessingState { get; init; }
    public EquatableArray<AudioAsset> AudioAssets { get; init; }

    /// <summary>Moments and sections marked while recording or afterwards.</summary>
    public RecordingNotes Notes { get; init; }

    /// <summary>Playback jumps over long silences in this recording.</summary>
    public bool SkipsSilences { get; init; }

    public IReadOnlyList<AudioAsset> PlaybackAudioAssets =>
        [.. AudioAssets
            .OrderBy(asset => asset.Role.PlaybackPriority())
            .ThenBy(asset => asset.Id.ToUuidString(), StringComparer.Ordinal)];

    private static EquatableArray<AudioSource> NormalizedSources(IEnumerable<AudioSource> sources) =>
        sources.Distinct().Order().ToEquatableArray();
}
