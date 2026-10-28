using Bardo.Diarization;
using Bardo.Domain;

namespace Bardo.Transcription;

/// <summary>A word with the diarization speaker it overlaps most, or none without evidence.</summary>
public sealed record SpeakerAttributedWord(TranscriptWord Word, int? SpeakerIndex);

/// <summary>A word with the transcript speaker it was given.</summary>
public sealed record AttributedTranscriptWord(TranscriptWord Word, Guid? SpeakerId = null);

public static class BardoWordSpeakerAligner
{
    public const int BoundaryRunMaximumWords = 2;
    public const double BoundaryRunMaximumDuration = 0.6;
    public const double ContiguousSpeechGap = 0.2;
    public const double ClearPause = 0.3;

    public static IReadOnlyList<SpeakerAttributedWord> Align(
        IEnumerable<TranscriptWord> words,
        IEnumerable<DiarizationInterval> intervals)
    {
        var validIntervals = intervals.Where(interval => interval.IsValid).ToList();
        return [.. words.Select(word => new SpeakerAttributedWord(word, BestSpeakerIndex(word, validIntervals)))];
    }

    public static IReadOnlyList<AttributedTranscriptWord> Attributed(
        IEnumerable<TranscriptWord> words,
        IEnumerable<DiarizationInterval> intervals,
        IReadOnlyDictionary<int, Guid> speakerIds) =>
        SmoothingBoundaryWords(
        [
            .. Align(words, intervals).Select(aligned => new AttributedTranscriptWord(
                aligned.Word,
                aligned.SpeakerIndex is { } index && speakerIds.TryGetValue(index, out var id) ? id : null)),
        ]);

    /// <summary>
    /// Diarization boundaries jitter by a few hundred milliseconds, so the first or last
    /// word of a turn often lands on the neighbouring voice ("…sprint." · "Me" | "parece
    /// bien…"). A run of at most two short words that belongs to the voice across a clear
    /// pause, but is spoken without a break into another voice's turn, is a leftover of
    /// that other turn and joins it. Short replies keep their speaker, and so do runs at
    /// the start or end of the conversation.
    /// </summary>
    public static IReadOnlyList<AttributedTranscriptWord> SmoothingBoundaryWords(IReadOnlyList<AttributedTranscriptWord> words)
    {
        if (words.Count <= 2) return words;

        // Runs break on a speaker change or on a clear pause within one speaker.
        var runs = new List<(int Start, int End)>();
        var start = 0;
        for (var index = 1; index <= words.Count; index++)
        {
            var ends = index == words.Count
                || words[index].SpeakerId != words[start].SpeakerId
                || words[index].Word.StartTime - words[index - 1].Word.EndTime >= ClearPause;
            if (ends)
            {
                runs.Add((start, index));
                start = index;
            }
        }
        if (runs.Count <= 2) return words;

        bool IsShort((int Start, int End) run) =>
            run.End - run.Start <= BoundaryRunMaximumWords
            && words[run.End - 1].Word.EndTime - words[run.Start].Word.StartTime <= BoundaryRunMaximumDuration;

        // Decisions read the already smoothed speakers, and a leftover only joins a
        // substantial turn: two short phrases in a quick exchange ("¿Vale?" "Vale.")
        // must not trade speakers.
        var smoothed = words.ToArray();
        for (var position = 1; position < runs.Count - 1; position++)
        {
            var run = runs[position];
            var previous = runs[position - 1];
            var next = runs[position + 1];
            if (!IsShort(run)) continue;

            var first = words[run.Start].Word;
            var last = words[run.End - 1].Word;
            var speaker = smoothed[run.Start].SpeakerId;
            var previousSpeaker = smoothed[previous.End - 1].SpeakerId;
            var nextSpeaker = smoothed[next.Start].SpeakerId;
            var gapBefore = first.StartTime - words[previous.End - 1].Word.EndTime;
            var gapAfter = words[next.Start].Word.StartTime - last.EndTime;

            Guid? target;
            if (gapAfter <= ContiguousSpeechGap && gapBefore >= ClearPause && !IsShort(next)
                && previousSpeaker == speaker && nextSpeaker != speaker)
            {
                target = nextSpeaker;
            }
            else if (gapBefore <= ContiguousSpeechGap && gapAfter >= ClearPause && !IsShort(previous)
                && nextSpeaker == speaker && previousSpeaker != speaker)
            {
                target = previousSpeaker;
            }
            else
            {
                continue;
            }
            if (target is null) continue;
            for (var index = run.Start; index < run.End; index++)
            {
                smoothed[index] = new AttributedTranscriptWord(words[index].Word, target);
            }
        }
        return smoothed;
    }

    private static int? BestSpeakerIndex(TranscriptWord word, IReadOnlyList<DiarizationInterval> intervals)
    {
        if (!double.IsFinite(word.StartTime) || !double.IsFinite(word.EndTime) || word.EndTime < word.StartTime)
        {
            return null;
        }

        var scores = new Dictionary<int, double>();
        if (word.StartTime == word.EndTime)
        {
            foreach (var interval in intervals)
            {
                if (word.StartTime >= interval.StartTime && word.StartTime <= interval.EndTime)
                {
                    scores[interval.SpeakerIndex] = scores.GetValueOrDefault(interval.SpeakerIndex) + 0.000_001;
                }
            }
        }
        else
        {
            foreach (var interval in intervals)
            {
                var overlap = Math.Max(0, Math.Min(word.EndTime, interval.EndTime) - Math.Max(word.StartTime, interval.StartTime));
                if (overlap > 0)
                {
                    scores[interval.SpeakerIndex] = scores.GetValueOrDefault(interval.SpeakerIndex) + overlap;
                }
            }
        }
        return HighestScoring(scores);
    }

    /// <summary>The speaker with the highest positive score; a tie goes to the lower index.</summary>
    internal static int? HighestScoring(IReadOnlyDictionary<int, double> scores)
    {
        int? best = null;
        var bestScore = 0.0;
        foreach (var (index, score) in scores)
        {
            if (score <= 0) continue;
            if (best is null || score > bestScore || (score == bestScore && index < best))
            {
                best = index;
                bestScore = score;
            }
        }
        return best;
    }
}
