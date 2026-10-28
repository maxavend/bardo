using System.Globalization;
using System.Resources;

namespace Bardo.Resources;

/// <summary>What transcription, speaker identification and model setup tell the person, in English and Spanish.</summary>
internal static class PipelineStrings
{
    private static readonly ResourceManager Resources = new("Bardo.Resources.PipelineStrings", typeof(PipelineStrings).Assembly);

    private static string Get(string name) => Resources.GetString(name, CultureInfo.CurrentUICulture) ?? name;

    private static string Format(string name, params object?[] arguments) =>
        string.Format(CultureInfo.CurrentCulture, Get(name), arguments);

    public static string ModelInUse => Get(nameof(ModelInUse));

    public static string TranscriptionNoManagedAudio(object? arg0) => Format(nameof(TranscriptionNoManagedAudio), arg0);

    public static string TranscriptionMixUnavailable => Get(nameof(TranscriptionMixUnavailable));

    public static string TranscriptionInvalidDuration => Get(nameof(TranscriptionInvalidDuration));

    public static string TranscriptionEmpty => Get(nameof(TranscriptionEmpty));

    public static string DiarizationNoManagedAudio(object? arg0) => Format(nameof(DiarizationNoManagedAudio), arg0);

    public static string DiarizationMixUnavailable => Get(nameof(DiarizationMixUnavailable));

    public static string DiarizationInvalidDuration => Get(nameof(DiarizationInvalidDuration));

    public static string DiarizationNoSpeakerActivity => Get(nameof(DiarizationNoSpeakerActivity));

    public static string DiarizationModelsUnavailable => Get(nameof(DiarizationModelsUnavailable));

    public static string DiarizationModelsNotLoaded => Get(nameof(DiarizationModelsNotLoaded));
}
