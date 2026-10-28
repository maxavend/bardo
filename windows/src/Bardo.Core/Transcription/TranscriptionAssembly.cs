using System.Globalization;
using Bardo.Domain;
using Bardo.Serialization;

namespace Bardo.Transcription;

/// <summary>
/// A word as a speech recogniser reports it: seconds from the start of the file it
/// heard, not of the recording.
/// </summary>
public sealed record RecognizedWord(double Start, double End, string Text, float? Probability = null);

/// <summary>
/// A stretch of text as a speech recogniser reports it: seconds from the start of the
/// file it heard, raw text that may still hold control tokens, and its word timings.
/// </summary>
public sealed record RecognizedSegment(double Start, double End, string Text, EquatableArray<RecognizedWord> Words = default);

/// <summary>A language a text was recognised to be in, and how sure the recogniser is.</summary>
public sealed record LanguageGuess(string Code, double Confidence);

/// <summary>Turns what a speech recogniser heard into a transcript's segments and speakers.</summary>
public static class TranscriptionAssembly
{
    /// <summary>Text shorter than this says too little about its language.</summary>
    public const int MinimumLanguageTextLength = 20;

    /// <summary>A language guess less sure than this is ignored.</summary>
    public const double MinimumLanguageConfidence = 0.6;

    /// <summary>
    /// One recognised segment placed on the recording's timeline and tagged with its track;
    /// null when nothing readable is left once control tokens are removed.
    /// </summary>
    public static TranscriptSegment? Segment(RecognizedSegment segment, TranscriptionPass pass)
    {
        var text = TranscriptTextSanitizer.NormalizeRecognizedText(segment.Text).Trim();
        if (text.Length == 0) return null;

        var words = segment.Words
            .Select(word => new TranscriptWord(word.Start + pass.Offset, word.End + pass.Offset, word.Text, word.Probability))
            .ToEquatableArray();
        return new TranscriptSegment(
            segment.Start + pass.Offset,
            segment.End + pass.Offset,
            text,
            words: words,
            source: pass.Source);
    }

    public static IReadOnlyList<TranscriptSegment> Segments(IEnumerable<RecognizedSegment> segments, TranscriptionPass pass) =>
        [.. segments.Select(segment => Segment(segment, pass)).OfType<TranscriptSegment>()];

    /// <summary>
    /// Whether a microphone segment repeats what the computer's audio already played, by
    /// its words or, when <paramref name="isAcousticEcho"/> can tell, by its sound. Used to
    /// keep the echo out of the live view as well as the result.
    /// </summary>
    public static Func<TranscriptSegment, bool> EchoFilter(
        IReadOnlyList<TranscriptSegment> heardOnSystem,
        Func<TranscriptSegment, bool>? isAcousticEcho = null) =>
        segment => TrackTranscriptMerger.IsEcho(segment, heardOnSystem) || (isAcousticEcho?.Invoke(segment) ?? false);

    /// <summary>
    /// The transcript's segments and speakers from every pass of <paramref name="plan"/>,
    /// <paramref name="segmentsPerPass"/> in the same order as its passes. Tracks
    /// transcribed apart become "You" and "Others" without the microphone's echo of the
    /// call; a single track has no speakers until they are identified.
    /// </summary>
    /// <exception cref="TranscriptionException">Nothing was recognised.</exception>
    public static (EquatableArray<TranscriptSegment> Segments, EquatableArray<Speaker> Speakers) Combine(
        TranscriptionPlan plan,
        IReadOnlyList<IReadOnlyList<TranscriptSegment>> segmentsPerPass,
        Func<TranscriptSegment, bool>? isAcousticEcho = null)
    {
        ArgumentOutOfRangeException.ThrowIfNotEqual(segmentsPerPass.Count, plan.Passes.Count, nameof(segmentsPerPass));

        IReadOnlyList<TranscriptSegment> HeardOn(TranscriptSource? source)
        {
            IReadOnlyList<TranscriptSegment> heard = [];
            for (var index = 0; index < plan.Passes.Count; index++)
            {
                if (plan.Passes[index].Source == source) heard = segmentsPerPass[index];
            }
            return heard;
        }

        (EquatableArray<TranscriptSegment> Segments, EquatableArray<Speaker> Speakers) combined = plan.IsPerTrack
            ? TrackTranscriptMerger.Merge(HeardOn(TranscriptSource.System), HeardOn(TranscriptSource.Microphone), isAcousticEcho)
            : (HeardOn(null)
                .OrderBy(segment => segment.StartTime)
                .ThenBy(segment => segment.Id.ToUuidString(), StringComparer.Ordinal)
                .ToEquatableArray(), []);
        if (combined.Segments.Count == 0) throw TranscriptionException.EmptyTranscription();
        return combined;
    }

    /// <summary>
    /// The language most of the text is in, as a Whisper language code ("es", not
    /// "es-CL"), when <paramref name="identify"/> is sure enough.
    /// </summary>
    public static string? DominantLanguage(IEnumerable<TranscriptSegment> segments, Func<string, LanguageGuess?> identify)
    {
        var text = string.Join(" ", segments.Select(segment => segment.Text));
        if (new StringInfo(text).LengthInTextElements < MinimumLanguageTextLength) return null;
        if (identify(text) is not { } guess || guess.Confidence < MinimumLanguageConfidence) return null;
        var separator = guess.Code.IndexOf('-', StringComparison.Ordinal);
        return separator < 0 ? guess.Code : guess.Code[..separator];
    }

    /// <summary>
    /// The transcript's language. A recogniser's own label can name the language of an
    /// early, nearly silent window; the recognised text says which language the
    /// conversation was in, and the recogniser's labels are only the fallback.
    /// </summary>
    public static string? LanguageCode(
        IEnumerable<TranscriptSegment> segments,
        Func<string, LanguageGuess?> identify,
        IEnumerable<string> recognizerLanguages) =>
        DominantLanguage(segments, identify) ?? recognizerLanguages.FirstOrDefault(language => language.Length > 0);
}
