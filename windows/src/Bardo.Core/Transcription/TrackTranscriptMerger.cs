using System.Globalization;
using System.Text;
using Bardo.Domain;
using Bardo.Serialization;

namespace Bardo.Transcription;

/// <summary>
/// Combines a recording's two tracks, transcribed apart, into one conversation.
/// </summary>
/// <remarks>
/// The microphone is always the person recording, so its turns belong to "You" and the
/// computer's audio to "Others" until participants are told apart. When the call plays
/// through speakers the microphone hears it again a moment later; those echoed turns
/// repeat what the computer's audio already said at the same time, and are left out. They
/// are recognised by their words and, through <c>isAcousticEcho</c>, by their sound.
/// </remarks>
public static class TrackTranscriptMerger
{
    /// <summary>How far apart the same word may be heard on both tracks and still be an echo.</summary>
    public const double EchoWindow = 1.0;

    /// <summary>The share of a microphone turn's words that must repeat the computer's audio.</summary>
    public const double EchoShare = 0.6;

    public static (EquatableArray<TranscriptSegment> Segments, EquatableArray<Speaker> Speakers) Merge(
        IReadOnlyList<TranscriptSegment> system,
        IReadOnlyList<TranscriptSegment> microphone,
        Func<TranscriptSegment, bool>? isAcousticEcho = null)
    {
        var own = microphone
            .Where(segment => !IsEcho(segment, system) && !(isAcousticEcho?.Invoke(segment) ?? false))
            .ToList();

        var speakers = new List<Speaker>();
        var segments = new List<TranscriptSegment>();
        if (own.Count > 0)
        {
            var you = new Speaker(role: SpeakerRole.LocalUser);
            speakers.Add(you);
            segments.AddRange(own.Select(segment => Assigned(segment, you, TranscriptSource.Microphone)));
        }
        if (system.Count > 0)
        {
            var others = new Speaker(role: SpeakerRole.Others);
            speakers.Add(others);
            segments.AddRange(system.Select(segment => Assigned(segment, others, TranscriptSource.System)));
        }

        var sorted = segments.OrderBy(segment => segment.StartTime).ThenBy(segment => segment.EndTime);
        return (sorted.ToEquatableArray(), speakers.ToEquatableArray());
    }

    /// <summary>
    /// Whether a microphone turn mostly repeats words the computer's audio played around the
    /// same time.
    /// </summary>
    public static bool IsEcho(TranscriptSegment segment, IReadOnlyList<TranscriptSegment> system)
    {
        var nearby = system
            .Where(played => played.StartTime - EchoWindow <= segment.EndTime && played.EndTime + EchoWindow >= segment.StartTime)
            .ToList();
        if (nearby.Count == 0) return false;

        var spoken = TimedWords(segment);
        if (spoken.Count == 0) return false;
        var played = nearby.SelectMany(TimedWords).ToList();

        var repeated = spoken.Count(word =>
            played.Any(candidate => candidate.Text == word.Text && Math.Abs(candidate.Time - word.Time) <= EchoWindow));
        return (double)repeated / spoken.Count >= EchoShare;
    }

    private static TranscriptSegment Assigned(TranscriptSegment segment, Speaker speaker, TranscriptSource source) =>
        segment with { SpeakerId = speaker.Id, Source = source };

    /// <summary>
    /// Each word with the moment it was said; without word timings the segment's words
    /// are spread evenly over its span.
    /// </summary>
    private static List<(string Text, double Time)> TimedWords(TranscriptSegment segment)
    {
        if (segment.Words.Count > 0)
        {
            var timed = new List<(string Text, double Time)>();
            foreach (var word in segment.Words)
            {
                if (Normalized(word.Text) is { } text) timed.Add((text, (word.StartTime + word.EndTime) / 2));
            }
            return timed;
        }
        var words = segment.Text
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(Normalized)
            .OfType<string>()
            .ToList();
        if (words.Count == 0) return [];
        var step = Math.Max(0, segment.EndTime - segment.StartTime) / words.Count;
        return [.. words.Select((text, index) => (text, segment.StartTime + step * (index + 0.5)))];
    }

    /// <summary>A word without case, accents or punctuation, so both tracks compare alike.</summary>
    private static string? Normalized(string word)
    {
        var builder = new StringBuilder(word.Length);
        foreach (var rune in SpeakerNaming.FoldedKey(word).EnumerateRunes())
        {
            if (IsAlphanumeric(rune)) builder.Append(rune.ToString());
        }
        return builder.Length == 0 ? null : builder.ToString();
    }

    /// <summary>Letters, marks and numbers, as in Foundation's <c>CharacterSet.alphanumerics</c>.</summary>
    private static bool IsAlphanumeric(Rune rune) => Rune.GetUnicodeCategory(rune) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };
}
