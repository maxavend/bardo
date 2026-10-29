using Bardo.Domain;
using Bardo.Resources;
using Bardo.Serialization;

namespace Bardo.Transcription;

public enum TranscriptionStage
{
    PreparingModel,
    LoadingModel,
    Transcribing,
    Saving,
}

public sealed record TranscriptionProgressSnapshot(TranscriptionStage Stage, double FractionCompleted);

/// <summary>What a running transcription has recognised so far, for the live view.</summary>
public sealed record TranscriptionLiveSnapshot(
    Guid RecordingId,
    EquatableArray<TranscriptSegment> Segments,
    string ProvisionalText,
    double ProcessedAudioTime,
    double AudioDuration)
{
    public double FractionCompleted =>
        double.IsFinite(AudioDuration) && AudioDuration > 0
            ? Math.Min(1, Math.Max(0, ProcessedAudioTime / AudioDuration))
            : 0;

    public static TranscriptionLiveSnapshot Empty(Guid recordingId, double audioDuration) =>
        new(recordingId, [], "", 0, audioDuration);
}

public enum TranscriptionErrorKind
{
    NoManagedAudio,
    CombinedAudioUnavailable,
    InvalidDuration,
    EmptyTranscription,
}

public sealed class TranscriptionException : Exception
{
    private TranscriptionException(TranscriptionErrorKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }

    public TranscriptionErrorKind Kind { get; }
    public Guid? RecordingId { get; private init; }

    public static TranscriptionException NoManagedAudio(Guid recordingId) =>
        new(TranscriptionErrorKind.NoManagedAudio, PipelineStrings.TranscriptionNoManagedAudio(recordingId.ToUuidString()))
        {
            RecordingId = recordingId,
        };

    public static TranscriptionException CombinedAudioUnavailable(Guid recordingId) =>
        new(TranscriptionErrorKind.CombinedAudioUnavailable, PipelineStrings.TranscriptionMixUnavailable) { RecordingId = recordingId };

    public static TranscriptionException InvalidDuration() =>
        new(TranscriptionErrorKind.InvalidDuration, PipelineStrings.TranscriptionInvalidDuration);

    public static TranscriptionException EmptyTranscription() =>
        new(TranscriptionErrorKind.EmptyTranscription, PipelineStrings.TranscriptionEmpty);
}
