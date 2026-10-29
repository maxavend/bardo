using System.Globalization;
using System.Resources;

namespace Bardo.Resources;

/// <summary>Bardo.Core's user-facing text, in English and Spanish.</summary>
internal static class Strings
{
    private static readonly ResourceManager Resources = new("Bardo.Resources.Strings", typeof(Strings).Assembly);

    private static string Get(string name) => Resources.GetString(name, CultureInfo.CurrentUICulture) ?? name;

    private static string Format(string name, params object?[] arguments) =>
        string.Format(CultureInfo.CurrentCulture, Get(name), arguments);

    public static string MomentTitle(object? arg0) => Format(nameof(MomentTitle), arg0);

    public static string SectionTitle(object? arg0) => Format(nameof(SectionTitle), arg0);

    public static string LocalSpeaker => Get(nameof(LocalSpeaker));

    public static string OtherSpeakers => Get(nameof(OtherSpeakers));

    public static string NumberedSpeaker(object? arg0) => Format(nameof(NumberedSpeaker), arg0);

    public static string UnknownDuration => Get(nameof(UnknownDuration));

    public static string CouldNotWrite(object? arg0, object? arg1) => Format(nameof(CouldNotWrite), arg0, arg1);

    public static string CouldNotPublish(object? arg0, object? arg1) => Format(nameof(CouldNotPublish), arg0, arg1);

    public static string CouldNotOperate(object? arg0, object? arg1, object? arg2) => Format(nameof(CouldNotOperate), arg0, arg1, arg2);

    public static string RecordingNotFound(object? arg0) => Format(nameof(RecordingNotFound), arg0);

    public static string RecordingAlreadyExists(object? arg0) => Format(nameof(RecordingAlreadyExists), arg0);

    public static string AudioAssetNotFound(object? arg0, object? arg1) => Format(nameof(AudioAssetNotFound), arg0, arg1);

    public static string AudioAssetFileSetMismatch(object? arg0, object? arg1, object? arg2) => Format(nameof(AudioAssetFileSetMismatch), arg0, arg1, arg2);

    public static string ManagedAudioMissing(object? arg0, object? arg1) => Format(nameof(ManagedAudioMissing), arg0, arg1);

    public static string ManifestUnsupportedSchema(object? arg0) => Format(nameof(ManifestUnsupportedSchema), arg0);

    public static string ManifestInvalid(object? arg0) => Format(nameof(ManifestInvalid), arg0);

    public static string ManifestIdentityMismatch(object? arg0, object? arg1) => Format(nameof(ManifestIdentityMismatch), arg0, arg1);

    public static string TranscriptNotFound(object? arg0) => Format(nameof(TranscriptNotFound), arg0);

    public static string TranscriptUnsupportedSchema(object? arg0) => Format(nameof(TranscriptUnsupportedSchema), arg0);

    public static string TranscriptInvalid(object? arg0) => Format(nameof(TranscriptInvalid), arg0);

    public static string TranscriptIdentityMismatch(object? arg0, object? arg1) => Format(nameof(TranscriptIdentityMismatch), arg0, arg1);

    public static string Yesterday => Get(nameof(Yesterday));

    public static string RecordingFrom(object? arg0) => Format(nameof(RecordingFrom), arg0);

    public static string SourceMicrophone => Get(nameof(SourceMicrophone));

    public static string SourceSystemAudio => Get(nameof(SourceSystemAudio));

    public static string SourceImportedFile => Get(nameof(SourceImportedFile));

    public static string UnknownSource => Get(nameof(UnknownSource));

    public static string ImportedAudio => Get(nameof(ImportedAudio));

    public static string UnsupportedAudioFormat(object? arg0) => Format(nameof(UnsupportedAudioFormat), arg0);

    public static string UnreadableAudio => Get(nameof(UnreadableAudio));

    public static string EmptyRecordingTitle => Get(nameof(EmptyRecordingTitle));

    public static string RecordingRenamed => Get(nameof(RecordingRenamed));

    public static string RecordingRecycled => Get(nameof(RecordingRecycled));

    public static string RecordingImported(object? arg0) => Format(nameof(RecordingImported), arg0);

    public static string Transcribing => Get(nameof(Transcribing));

    public static string IdentifyingSpeakers => Get(nameof(IdentifyingSpeakers));

    public static string TranscriptionFailed(object? arg0) => Format(nameof(TranscriptionFailed), arg0);

    public static string SpeakerIdentificationFailed(object? arg0) => Format(nameof(SpeakerIdentificationFailed), arg0);

    public static string EmptySpeakerName => Get(nameof(EmptySpeakerName));
}
