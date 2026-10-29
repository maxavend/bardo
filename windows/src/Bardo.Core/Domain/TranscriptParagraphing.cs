namespace Bardo.Domain;

/// <summary>
/// How a transcript is broken into paragraphs for reading: each turn of the
/// conversation on its own, and within a turn, paragraphs of a comfortable length. A
/// short breath does not leave a line of five words behind, and a long monologue does
/// not become a wall of text.
/// </summary>
public static class TranscriptParagraphing
{
    /// <summary>A paragraph shorter than this keeps going through ordinary pauses.</summary>
    public const int MinimumWords = 20;

    /// <summary>Past this, a paragraph ends at the next sentence that ends.</summary>
    public const int ComfortableWords = 70;

    /// <summary>A paragraph that still has not reached a sentence's end stops here regardless.</summary>
    public const int MaximumWords = 120;

    /// <summary>A pause long enough to end a paragraph once it has its minimum.</summary>
    public const double Pause = 2.5;

    /// <summary>A silence that always starts a new paragraph.</summary>
    public const double Silence = 6;

    private const string SentenceEnds = ".?!…";

    /// <summary>The segments, in order, grouped into paragraphs.</summary>
    public static IReadOnlyList<IReadOnlyList<TranscriptSegment>> Paragraphs(IEnumerable<TranscriptSegment> segments)
    {
        var paragraphs = new List<IReadOnlyList<TranscriptSegment>>();
        var current = new List<TranscriptSegment>();
        var words = 0;

        foreach (var segment in segments)
        {
            if (current.Count > 0)
            {
                var last = current[^1];
                var gap = segment.StartTime - last.EndTime;
                var speakerChanged = segment.SpeakerId != last.SpeakerId;
                var trimmed = last.DisplayText.Trim(' ', '\t');
                var endsSentence = trimmed.Length > 0 && SentenceEnds.Contains(trimmed[^1], StringComparison.Ordinal);
                var shouldBreak = speakerChanged
                    || gap >= Silence
                    || (gap >= Pause && words >= MinimumWords)
                    || (words >= ComfortableWords && endsSentence)
                    || words >= MaximumWords;
                if (shouldBreak)
                {
                    paragraphs.Add(current);
                    current = [];
                    words = 0;
                }
            }
            current.Add(segment);
            words += WordCount(segment.DisplayText);
        }
        if (current.Count > 0) paragraphs.Add(current);
        return paragraphs;
    }

    public static int WordCount(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
}
