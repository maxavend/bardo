using Bardo.Domain;
using Bardo.Serialization;

namespace Bardo.Transcription;

/// <summary>
/// Groups words that already know their speaker into the turns of a conversation: a new
/// turn on every change of voice, after a long pause, after a sentence that ends with a
/// pause, and at a natural break once a monologue runs long.
/// </summary>
public static class BardoConversationTurnBuilder
{
    public const double MediumPause = 0.45;
    public const double StrongPause = 1.2;
    public const double SoftMaximumDuration = 32;

    private const string SentenceEnds = ".!?…";
    private const string AttachedPunctuation = ",.!?;:%)]}";

    public static IReadOnlyList<TranscriptSegment> Build(IEnumerable<AttributedTranscriptWord> words)
    {
        var validWords = words
            .Where(word => double.IsFinite(word.Word.StartTime)
                && double.IsFinite(word.Word.EndTime)
                && word.Word.EndTime >= word.Word.StartTime
                && !string.IsNullOrWhiteSpace(word.Word.Text))
            .ToList();
        if (validWords.Count == 0) return [];

        var turns = new List<TranscriptSegment>();
        var current = new List<AttributedTranscriptWord>();

        void Flush()
        {
            if (current.Count == 0) return;
            var first = current[0];
            var last = current[^1];
            var text = JoinText(current.Select(word => word.Word.Text));
            if (text.Length > 0)
            {
                turns.Add(new TranscriptSegment(
                    first.Word.StartTime,
                    last.Word.EndTime,
                    text,
                    speakerId: first.SpeakerId,
                    words: current.Select(word => word.Word).ToEquatableArray()));
            }
            current.Clear();
        }

        foreach (var word in validWords)
        {
            if (current.Count > 0 && ShouldStartNewTurn(current[^1], word, current[0].Word.StartTime))
            {
                Flush();
            }
            current.Add(word);
        }
        Flush();
        return turns;
    }

    private static bool ShouldStartNewTurn(AttributedTranscriptWord previous, AttributedTranscriptWord next, double currentStart)
    {
        if (previous.SpeakerId != next.SpeakerId) return true;

        var gap = Math.Max(0, next.Word.StartTime - previous.Word.EndTime);
        if (gap >= StrongPause) return true;

        var trimmed = previous.Word.Text.Trim();
        var sentenceEnded = trimmed.Length > 0 && SentenceEnds.Contains(trimmed[^1], StringComparison.Ordinal);
        if (sentenceEnded && gap >= MediumPause) return true;

        var duration = next.Word.EndTime - currentStart;
        return duration >= SoftMaximumDuration && (sentenceEnded || gap >= MediumPause);
    }

    private static string JoinText(IEnumerable<string> tokens)
    {
        var result = "";
        foreach (var token in tokens)
        {
            if (token.Length == 0) continue;
            if (result.Length == 0)
            {
                result = token;
            }
            else if (char.IsWhiteSpace(token[0]) || AttachedPunctuation.Contains(token[0], StringComparison.Ordinal))
            {
                result += token;
            }
            else
            {
                result += " " + token;
            }
        }
        return result.Trim();
    }
}
