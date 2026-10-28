using System.Text.Json.Serialization;
using Bardo.Serialization;

namespace Bardo.Domain;

/// <summary>Who a speaker is when Bardo knows it from the track they were heard on.</summary>
public enum SpeakerRole
{
    /// <summary>The person recording, heard on the microphone track.</summary>
    LocalUser,

    /// <summary>Everyone heard on the computer's audio before participants are told apart.</summary>
    Others,
}

public sealed record Speaker
{
    public Speaker(string? name = null, SpeakerRole? role = null, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Name = name;
        Role = role;
    }

    [JsonConstructor]
    private Speaker(Guid id, string? name = null, SpeakerRole? role = null) : this(name, role, id)
    {
    }

    public Guid Id { get; }
    public string? Name { get; init; }
    public SpeakerRole? Role { get; init; }
}

/// <summary>The original track a segment was recognised from, when tracks were transcribed apart.</summary>
public enum TranscriptSource
{
    Microphone,
    System,
}

/// <summary>How a recording with a microphone and a system audio track is transcribed.</summary>
public enum TranscriptionTrackMode
{
    /// <summary>Each track on its own: no overlapping voices, and the microphone is always you.</summary>
    PerTrack,

    /// <summary>The combined conversation mix, as one recording.</summary>
    Mix,
}

public sealed record TranscriptWord
{
    public TranscriptWord(double startTime, double endTime, string text, float? probability = null, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        StartTime = startTime;
        EndTime = endTime;
        Text = text;
        Probability = probability;
    }

    [JsonConstructor]
    private TranscriptWord(Guid id, double startTime, double endTime, string text, float? probability = null)
        : this(startTime, endTime, text, probability, id)
    {
    }

    public Guid Id { get; }
    public double StartTime { get; }
    public double EndTime { get; }
    public string Text { get; }
    public float? Probability { get; }
}

public sealed record TranscriptSegment
{
    public TranscriptSegment(
        double startTime,
        double endTime,
        string text,
        Guid? speakerId = null,
        EquatableArray<TranscriptWord> words = default,
        string? editedText = null,
        TranscriptSource? source = null,
        Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        StartTime = startTime;
        EndTime = endTime;
        SpeakerId = speakerId;
        Text = text;
        Words = words;
        EditedText = editedText;
        Source = source;
    }

    [JsonConstructor]
    private TranscriptSegment(
        Guid id,
        double startTime,
        double endTime,
        string text,
        EquatableArray<TranscriptWord> words,
        Guid? speakerId = null,
        string? editedText = null,
        TranscriptSource? source = null)
        : this(startTime, endTime, text, speakerId, words, editedText, source, id)
    {
    }

    public Guid Id { get; }
    public double StartTime { get; }
    public double EndTime { get; }

    [JsonPropertyName("speakerID")]
    public Guid? SpeakerId { get; init; }

    public string Text { get; init; }
    public EquatableArray<TranscriptWord> Words { get; init; }
    public string? EditedText { get; init; }
    public TranscriptSource? Source { get; init; }

    [JsonIgnore]
    public string DisplayText => TranscriptTextSanitizer.Sanitize(EditedText ?? Text);
}

public enum TranscriptionBackend
{
    WhisperKit,
    AppleSpeech,
}

/// <summary>
/// Which engine and model made a transcript. Transcripts from before Bardo offered a
/// choice read as Whisper large-v3 Turbo, the one engine there was.
/// </summary>
[JsonConverter(typeof(TranscriptionSelectionJsonConverter))]
public sealed record TranscriptionSelection(
    TranscriptionBackend Backend = TranscriptionBackend.WhisperKit,
    string ModelId = TranscriptionSelection.TurboModelId)
{
    public const string TurboModelId = "large-v3-v20240930_turbo_632MB";
    public const string LargeModelId = "large-v3";
    public const string AppleModelId = "apple";
}

public sealed record TranscriptMetadata
{
    public TranscriptMetadata(
        string engine,
        string engineVersion,
        string modelId,
        TranscriptionSelection? selection = null,
        DateTimeOffset? createdAt = null,
        double? processingDuration = null,
        TranscriptionTrackMode? trackMode = null)
    {
        Engine = engine;
        EngineVersion = engineVersion;
        ModelId = modelId;
        Selection = selection;
        CreatedAt = BardoTime.Normalize(createdAt ?? DateTimeOffset.UtcNow);
        ProcessingDuration = processingDuration;
        TrackMode = trackMode;
    }

    [JsonConstructor]
    private TranscriptMetadata(
        string engine,
        string engineVersion,
        string modelId,
        DateTimeOffset createdAt,
        TranscriptionSelection? selection = null,
        double? processingDuration = null,
        TranscriptionTrackMode? trackMode = null)
        : this(engine, engineVersion, modelId, selection, (DateTimeOffset?)createdAt, processingDuration, trackMode)
    {
    }

    public string Engine { get; }
    public string EngineVersion { get; }

    [JsonPropertyName("modelID")]
    public string ModelId { get; }

    public TranscriptionSelection? Selection { get; }

    public DateTimeOffset CreatedAt { get; }

    public double? ProcessingDuration { get; }

    /// <summary>Set when a recording's tracks were transcribed apart or as their mix.</summary>
    public TranscriptionTrackMode? TrackMode { get; }
}

public sealed record DiarizationMetadata
{
    public DiarizationMetadata(
        string engine,
        string engineVersion,
        string modelId,
        DateTimeOffset? createdAt = null,
        double? processingDuration = null)
    {
        Engine = engine;
        EngineVersion = engineVersion;
        ModelId = modelId;
        CreatedAt = BardoTime.Normalize(createdAt ?? DateTimeOffset.UtcNow);
        ProcessingDuration = processingDuration;
    }

    [JsonConstructor]
    private DiarizationMetadata(string engine, string engineVersion, string modelId, DateTimeOffset createdAt, double? processingDuration = null)
        : this(engine, engineVersion, modelId, (DateTimeOffset?)createdAt, processingDuration)
    {
    }

    public string Engine { get; }
    public string EngineVersion { get; }

    [JsonPropertyName("modelID")]
    public string ModelId { get; }

    public DateTimeOffset CreatedAt { get; }

    public double? ProcessingDuration { get; }
}

public sealed record Transcript
{
    public Transcript(
        Guid recordingId,
        TranscriptMetadata metadata,
        string? languageCode = null,
        EquatableArray<Speaker> speakers = default,
        EquatableArray<TranscriptSegment> segments = default,
        DiarizationMetadata? diarizationMetadata = null)
    {
        RecordingId = recordingId;
        LanguageCode = languageCode;
        Speakers = speakers;
        Segments = segments;
        Metadata = metadata;
        DiarizationMetadata = diarizationMetadata;
    }

    [JsonConstructor]
    private Transcript(
        Guid recordingId,
        EquatableArray<Speaker> speakers,
        EquatableArray<TranscriptSegment> segments,
        TranscriptMetadata metadata,
        string? languageCode = null,
        DiarizationMetadata? diarizationMetadata = null)
        : this(recordingId, metadata, languageCode, speakers, segments, diarizationMetadata)
    {
    }

    [JsonPropertyName("recordingID")]
    public Guid RecordingId { get; }

    public string? LanguageCode { get; init; }

    public EquatableArray<Speaker> Speakers { get; init; }
    public EquatableArray<TranscriptSegment> Segments { get; init; }

    public TranscriptMetadata Metadata { get; }
    public DiarizationMetadata? DiarizationMetadata { get; init; }

    [JsonIgnore]
    public string Text => string.Join(
        "\n",
        Segments.Select(segment => segment.DisplayText).Where(text => text.Length > 0)).Trim();

    [JsonIgnore]
    public bool HasManualTextEdits => Segments.Any(segment => segment.EditedText is not null);

    [JsonIgnore]
    public bool HasNamedSpeakers => Speakers.Any(speaker => speaker.Name.NonEmptyTrimmed() is not null);

    [JsonIgnore]
    public bool HasManualChanges => HasManualTextEdits || HasNamedSpeakers;

    /// <summary>Whether the microphone and the computer's audio were transcribed apart.</summary>
    [JsonIgnore]
    public bool IsPerTrack => Metadata.TrackMode == TranscriptionTrackMode.PerTrack;
}
