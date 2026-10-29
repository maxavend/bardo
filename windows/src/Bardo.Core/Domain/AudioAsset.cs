using System.Text.Json.Serialization;
using Bardo.Serialization;

namespace Bardo.Domain;

public enum AudioAssetRole
{
    ImportedOriginal,
    MicrophoneOriginal,
    SystemOriginal,
    ConversationMix,
}

public static class AudioAssetRoleExtensions
{
    public static bool IsDerived(this AudioAssetRole role) => role == AudioAssetRole.ConversationMix;

    public static int PlaybackPriority(this AudioAssetRole role) => role switch
    {
        AudioAssetRole.ConversationMix => 0,
        AudioAssetRole.ImportedOriginal => 1,
        AudioAssetRole.SystemOriginal => 2,
        AudioAssetRole.MicrophoneOriginal => 3,
        _ => throw new ArgumentOutOfRangeException(nameof(role)),
    };
}

public sealed record AudioMetadata(double Duration, string Codec, double SampleRate, uint ChannelCount);

public sealed record AudioAsset
{
    public AudioAsset(
        string originalFileName,
        string fileExtension,
        AudioMetadata metadata,
        AudioAssetRole role = AudioAssetRole.ImportedOriginal,
        double timelineOffset = 0,
        EquatableArray<Guid> derivedFromAssetIds = default,
        Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        OriginalFileName = originalFileName;
        FileExtension = fileExtension.ToLowerInvariant();
        Metadata = metadata;
        Role = role;
        TimelineOffset = Math.Max(0, double.IsFinite(timelineOffset) ? timelineOffset : 0);
        DerivedFromAssetIds = derivedFromAssetIds;
    }

    public Guid Id { get; }
    public string OriginalFileName { get; }
    public string FileExtension { get; }
    public AudioMetadata Metadata { get; init; }
    public AudioAssetRole Role { get; }
    public double TimelineOffset { get; }

    [JsonPropertyName("derivedFromAssetIDs")]
    public EquatableArray<Guid> DerivedFromAssetIds { get; }
}
