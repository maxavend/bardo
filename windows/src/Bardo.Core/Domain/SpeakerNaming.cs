using System.Globalization;
using System.Text;
using Bardo.Resources;
using Bardo.Serialization;

namespace Bardo.Domain;

/// <summary>The name the person gave themselves in Settings, used for their microphone track.</summary>
public static class LocalSpeakerName
{
    /// <summary>Set by the app to read the name from its settings.</summary>
    public static Func<string?> Provider { get; set; } = () => null;

    public static string? Current => Provider().NonEmptyTrimmed();
}

public static class SpeakerNaming
{
    /// <summary>
    /// What a speaker is called on screen and in exports: the name someone typed, or
    /// else what Bardo knows about them.
    /// </summary>
    public static string DisplayName(this Transcript transcript, Speaker speaker, string? localName) =>
        speaker.Name.NonEmptyTrimmed() ?? transcript.DefaultName(speaker, localName);

    public static string DisplayName(this Transcript transcript, Speaker speaker) =>
        transcript.DisplayName(speaker, LocalSpeakerName.Current);

    /// <summary>
    /// What a speaker is called before anyone names them: "You" for the microphone,
    /// "Others" for the computer's audio before participants are told apart, and a
    /// number counted among the remaining speakers otherwise.
    /// </summary>
    public static string DefaultName(this Transcript transcript, Speaker speaker, string? localName)
    {
        switch (speaker.Role)
        {
            case SpeakerRole.LocalUser:
                return localName ?? Strings.LocalSpeaker;
            case SpeakerRole.Others:
                return Strings.OtherSpeakers;
            default:
                var numbered = transcript.Speakers.Where(candidate => candidate.Role is null).ToList();
                var index = numbered.FindIndex(candidate => candidate.Id == speaker.Id);
                return Strings.NumberedSpeaker(Math.Max(index, 0) + 1);
        }
    }

    public static Speaker? Speaker(this Transcript transcript, Guid? id) =>
        id is { } value ? transcript.Speakers.FirstOrDefault(speaker => speaker.Id == value) : null;

    /// <summary>
    /// The transcript with everything <paramref name="sourceId"/> said given to
    /// <paramref name="targetId"/>, for one person that was told apart as two. You on the
    /// microphone always stay you, and a name someone typed is kept when the other has none.
    /// </summary>
    public static Transcript MergingSpeaker(this Transcript transcript, Guid sourceId, Guid targetId)
    {
        if (sourceId == targetId
            || transcript.Speaker(sourceId) is not { } source
            || transcript.Speaker(targetId) is not { } target)
        {
            return transcript;
        }
        var (kept, removed) = source.Role == SpeakerRole.LocalUser && target.Role != SpeakerRole.LocalUser
            ? (source, target)
            : (target, source);

        var speakers = transcript.Speakers
            .Where(speaker => speaker.Id != removed.Id)
            .Select(speaker => speaker.Id == kept.Id && kept.Name.NonEmptyTrimmed() is null
                ? speaker with { Name = removed.Name.NonEmptyTrimmed() }
                : speaker)
            .ToEquatableArray();
        var segments = transcript.Segments
            .Select(segment => segment.SpeakerId == removed.Id ? segment with { SpeakerId = kept.Id } : segment)
            .ToEquatableArray();
        return transcript with { Speakers = speakers, Segments = segments };
    }

    /// <summary>Participants given the same name, which are most likely one person.</summary>
    public static IReadOnlyList<IReadOnlyList<Guid>> SpeakersSharingAName(
        this Transcript transcript,
        IReadOnlyDictionary<Guid, string> names)
    {
        var groups = new Dictionary<string, List<Guid>>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var speaker in transcript.Speakers)
        {
            var name = (names.TryGetValue(speaker.Id, out var typed) ? typed : speaker.Name).NonEmptyTrimmed();
            if (name is null) continue;
            var key = FoldedKey(name);
            if (!groups.TryGetValue(key, out var group))
            {
                groups[key] = group = [];
                order.Add(key);
            }
            group.Add(speaker.Id);
        }
        return [.. order.Select(key => (IReadOnlyList<Guid>)groups[key]).Where(group => group.Count > 1)];
    }

    /// <summary>A name without case or accents, so "José" and "jose" are the same person.</summary>
    internal static string FoldedKey(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(decomposed.Length);
        foreach (var character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark)
                builder.Append(character);
        }
        return builder.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }
}
