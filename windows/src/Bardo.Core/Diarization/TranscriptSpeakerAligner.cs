using Bardo.Domain;
using Bardo.Serialization;
using Bardo.Transcription;

namespace Bardo.Diarization;

/// <summary>
/// One stretch of a voice as a speaker identification engine reports it: seconds from the
/// start of the audio it heard, and the engine's index for the voice, or null when the
/// engine heard speech it could not give to anyone.
/// </summary>
public sealed record SpeakerTurn(int? SpeakerIndex, double StartTime, double EndTime);

/// <summary>One stretch of a voice on the recording's timeline.</summary>
public sealed record DiarizationInterval(int SpeakerIndex, double StartTime, double EndTime)
{
    internal bool IsValid =>
        SpeakerIndex >= 0 && double.IsFinite(StartTime) && double.IsFinite(EndTime) && EndTime > StartTime;
}

/// <summary>
/// Applies speaker intervals to words and reconstructs natural conversation turns.
/// Existing text edits and old transcripts without word timestamps remain intact.
/// </summary>
public static class TranscriptSpeakerAligner
{
    /// <summary>
    /// An engine's turns placed on the recording's timeline; turns it could not give to a
    /// voice are left out.
    /// </summary>
    public static IReadOnlyList<DiarizationInterval> Intervals(IEnumerable<SpeakerTurn> turns, double timelineOffset) =>
    [
        .. turns
            .Where(turn => turn.SpeakerIndex is not null)
            .Select(turn => new DiarizationInterval(
                turn.SpeakerIndex!.Value,
                turn.StartTime + timelineOffset,
                turn.EndTime + timelineOffset)),
    ];

    /// <summary>
    /// The transcript with its speakers identified from the audio
    /// <see cref="DiarizationAudio.ResolveAsync"/> chose: only the others' track for a
    /// transcript made per track, the whole conversation otherwise.
    /// </summary>
    public static Transcript Identify(
        Transcript transcript,
        DiarizationAudio audio,
        IEnumerable<SpeakerTurn> turns,
        DiarizationMetadata metadata)
    {
        var intervals = Intervals(turns, audio.TimelineOffset);
        return audio.IsOthersTrack
            ? ApplyingToOthers(intervals, transcript, metadata)
            : Applying(intervals, transcript, metadata);
    }

    /// <exception cref="DiarizationException">No interval has a voice.</exception>
    public static Transcript Applying(
        IEnumerable<DiarizationInterval> intervals,
        Transcript transcript,
        DiarizationMetadata metadata)
    {
        var validIntervals = intervals
            .Where(interval => interval.IsValid)
            .OrderBy(interval => interval.StartTime)
            .ThenBy(interval => interval.EndTime)
            .ThenBy(interval => interval.SpeakerIndex)
            .ToList();
        if (validIntervals.Count == 0) throw DiarizationException.NoSpeakerActivity();

        var order = OrderedSpeakerIndices(validIntervals);
        var speakers = SpeakersForDiarization(order, transcript);
        var speakerIds = order
            .Select((index, position) => (index, speakers[position].Id))
            .ToDictionary(pair => pair.index, pair => pair.Id);

        var updated = transcript with
        {
            Speakers = speakers.ToEquatableArray(),
            DiarizationMetadata = metadata,
        };

        if (transcript.HasManualTextEdits || transcript.Segments.All(segment => segment.Words.Count == 0))
        {
            return updated with
            {
                Segments = updated.Segments
                    .Select(segment => segment with { SpeakerId = BestSpeakerId(segment, validIntervals, speakerIds) })
                    .ToEquatableArray(),
            };
        }

        var words = transcript.Segments
            .SelectMany(segment => segment.Words)
            .OrderBy(word => word.StartTime)
            .ThenBy(word => word.EndTime);
        var attributedWords = BardoWordSpeakerAligner.Attributed(words, validIntervals, speakerIds);
        var rebuilt = BardoConversationTurnBuilder.Build(attributedWords);
        return rebuilt.Count > 0 ? updated with { Segments = rebuilt.ToEquatableArray() } : updated;
    }

    /// <summary>
    /// For a transcript whose tracks were transcribed apart: tells apart the participants
    /// heard on the computer's audio and leaves the microphone's turns with the person
    /// recording. <paramref name="intervals"/> must be on the recording's timeline.
    /// </summary>
    /// <exception cref="DiarizationException">No interval has a voice.</exception>
    public static Transcript ApplyingToOthers(
        IEnumerable<DiarizationInterval> intervals,
        Transcript transcript,
        DiarizationMetadata metadata)
    {
        var local = transcript.Speakers.Where(speaker => speaker.Role == SpeakerRole.LocalUser).ToList();
        var own = transcript.Segments.Where(segment => segment.Source == TranscriptSource.Microphone).ToList();

        // The undifferentiated "Others" gives way to the participants found, unless
        // someone already named it; then that name is kept for the first of them.
        var others = transcript with
        {
            Segments = transcript.Segments.Where(segment => segment.Source != TranscriptSource.Microphone).ToEquatableArray(),
            Speakers = transcript.Speakers
                .Select(speaker => speaker.Role switch
                {
                    SpeakerRole.LocalUser => null,
                    SpeakerRole.Others => speaker.Name.NonEmptyTrimmed() is null ? null : speaker with { Role = null },
                    _ => speaker,
                })
                .OfType<Speaker>()
                .ToEquatableArray(),
        };

        var aligned = Applying(intervals, others, metadata);
        return aligned with
        {
            Speakers = local.Concat(aligned.Speakers).ToEquatableArray(),
            Segments = own
                .Concat(aligned.Segments.Select(segment => segment with { Source = TranscriptSource.System }))
                .OrderBy(segment => segment.StartTime)
                .ThenBy(segment => segment.EndTime)
                .ToEquatableArray(),
        };
    }

    private static List<int> OrderedSpeakerIndices(IEnumerable<DiarizationInterval> intervals)
    {
        var seen = new HashSet<int>();
        return [.. intervals.Select(interval => interval.SpeakerIndex).Where(seen.Add)];
    }

    private static List<Speaker> SpeakersForDiarization(IReadOnlyList<int> order, Transcript transcript)
    {
        var existingIds = new List<Guid>();
        var seen = new HashSet<Guid>();
        foreach (var segment in transcript.Segments)
        {
            if (segment.SpeakerId is { } id && seen.Add(id)) existingIds.Add(id);
        }
        foreach (var speaker in transcript.Speakers)
        {
            if (seen.Add(speaker.Id)) existingIds.Add(speaker.Id);
        }

        return
        [
            .. order.Select((_, index) =>
                index < existingIds.Count && transcript.Speakers.FirstOrDefault(speaker => speaker.Id == existingIds[index]) is { } existing
                    ? existing
                    : new Speaker()),
        ];
    }

    private static Guid? BestSpeakerId(
        TranscriptSegment segment,
        IReadOnlyList<DiarizationInterval> intervals,
        Dictionary<int, Guid> speakerIds)
    {
        IReadOnlyList<TranscriptWord> words = segment.Words.Count == 0
            ? [new TranscriptWord(segment.StartTime, segment.EndTime, segment.Text)]
            : segment.Words;
        var scores = new Dictionary<int, double>();
        foreach (var word in BardoWordSpeakerAligner.Align(words, intervals))
        {
            if (word.SpeakerIndex is { } index) scores[index] = scores.GetValueOrDefault(index) + 1;
        }
        return BardoWordSpeakerAligner.HighestScoring(scores) is { } best && speakerIds.TryGetValue(best, out var id) ? id : null;
    }
}
