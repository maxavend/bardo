using Bardo.Resources;
using Bardo.Serialization;

namespace Bardo.Diarization;

public enum DiarizationErrorKind
{
    NoManagedAudio,
    CombinedAudioUnavailable,
    InvalidDuration,
    NoSpeakerActivity,
    SpeakerModelsUnavailable,
    SpeakerModelsNotLoaded,
}

public sealed class DiarizationException : Exception
{
    private DiarizationException(DiarizationErrorKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }

    public DiarizationErrorKind Kind { get; }
    public Guid? RecordingId { get; private init; }

    public static DiarizationException NoManagedAudio(Guid recordingId) =>
        new(DiarizationErrorKind.NoManagedAudio, PipelineStrings.DiarizationNoManagedAudio(recordingId.ToUuidString()))
        {
            RecordingId = recordingId,
        };

    public static DiarizationException CombinedAudioUnavailable(Guid recordingId) =>
        new(DiarizationErrorKind.CombinedAudioUnavailable, PipelineStrings.DiarizationMixUnavailable) { RecordingId = recordingId };

    public static DiarizationException InvalidDuration() =>
        new(DiarizationErrorKind.InvalidDuration, PipelineStrings.DiarizationInvalidDuration);

    public static DiarizationException NoSpeakerActivity() =>
        new(DiarizationErrorKind.NoSpeakerActivity, PipelineStrings.DiarizationNoSpeakerActivity);

    public static DiarizationException SpeakerModelsUnavailable() =>
        new(DiarizationErrorKind.SpeakerModelsUnavailable, PipelineStrings.DiarizationModelsUnavailable);

    public static DiarizationException SpeakerModelsNotLoaded() =>
        new(DiarizationErrorKind.SpeakerModelsNotLoaded, PipelineStrings.DiarizationModelsNotLoaded);
}

public enum DiarizationStage
{
    PreparingModel,
    LoadingModel,
    Diarizing,
    Saving,
}

public sealed record DiarizationProgressSnapshot(DiarizationStage Stage, double FractionCompleted);
