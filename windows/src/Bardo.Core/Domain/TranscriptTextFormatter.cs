namespace Bardo.Domain;

/// <summary>
/// A transcript as plain text to copy, share or export: the conversation's title and date,
/// then one block per stretch of speech, headed by who spoke and when.
/// </summary>
/// <remarks>
/// Blocks follow the conversation rather than the clock: everything one person says
/// without a long pause is one block, however long, and a new block starts when someone
/// else speaks or after a pause. Without speakers, long stretches are still split so the
/// text stays readable.
/// </remarks>
public sealed class TranscriptTextFormatter
{
    /// <summary>Without speakers to break it up, a block ends at the first segment past this length.</summary>
    public const double UnlabeledBlockLength = 120;

    public sealed record Block(string? Speaker, double Start, double End, string Text);

    public TranscriptTextFormatter(
        string title,
        DateTimeOffset? date = null,
        double? duration = null,
        RecordingNotes? notes = null,
        string? localName = null)
    {
        Title = title;
        Date = date;
        Duration = duration;
        Notes = notes ?? RecordingNotes.Empty;
        LocalName = localName;
    }

    public string Title { get; }
    public DateTimeOffset? Date { get; }
    public double? Duration { get; }
    public string? LocalName { get; }

    /// <summary>Sections become headings and moments are listed where they were marked.</summary>
    public RecordingNotes Notes { get; }

    public string Text(Transcript transcript)
    {
        var lines = new List<string> { Title };
        var details = new List<string>();
        if (Date is { } date) details.Add(DateFormatting.LongDate(date));
        if (Duration is { } duration) details.Add(DurationFormatting.Duration(duration));
        if (details.Count > 0) lines.Add(string.Join(" · ", details));

        var blocks = Blocks(transcript);
        var placement = new TranscriptNotePlacement(Notes, [.. blocks.Select(block => block.Start)]);
        if (placement.LeadingMoments.Count > 0)
        {
            lines.Add("");
            lines.AddRange(placement.LeadingMoments.Select(MomentLine));
        }
        for (var index = 0; index < blocks.Count; index++)
        {
            var block = blocks[index];
            foreach (var section in placement.SectionsBefore(index))
            {
                lines.AddRange(["", SectionLine(section)]);
            }
            lines.Add("");
            var range = $"{DurationFormatting.Duration(block.Start)}–{DurationFormatting.Duration(block.End)}";
            lines.Add(block.Speaker is { } speaker ? $"{speaker} ({range})" : range);
            lines.Add(block.Text);
            lines.AddRange(placement.MomentsAfter(index).Select(MomentLine));
        }
        foreach (var section in placement.TrailingSections)
        {
            lines.AddRange(["", SectionLine(section)]);
        }
        return string.Join("\n", lines);
    }

    public IReadOnlyList<Block> Blocks(Transcript transcript)
    {
        var names = new Dictionary<Guid, string>();
        foreach (var speaker in transcript.Speakers)
        {
            names.TryAdd(speaker.Id, transcript.DisplayName(speaker, LocalName));
        }
        string? NameOf(TranscriptSegment segment) =>
            segment.SpeakerId is { } id && names.TryGetValue(id, out var name) ? name : null;

        // The same paragraphs as on screen: each turn on its own, of a comfortable length.
        var segments = transcript.Segments
            .OrderBy(segment => segment.StartTime)
            .Where(segment => segment.DisplayText.Trim().Length > 0);

        var groups = TranscriptParagraphing.Paragraphs(segments).SelectMany(group =>
        {
            // Without names, long stretches still get a heading every couple of minutes,
            // so a time can be found.
            if (group.Count == 0 || NameOf(group[0]) is not null) return [group];
            var parts = new List<List<TranscriptSegment>> { new() };
            var partStart = group[0].StartTime;
            foreach (var segment in group)
            {
                if (parts[^1].Count > 0 && segment.EndTime - partStart > UnlabeledBlockLength)
                {
                    parts.Add([]);
                    partStart = segment.StartTime;
                }
                parts[^1].Add(segment);
            }
            return parts.Cast<IReadOnlyList<TranscriptSegment>>();
        });

        return [.. groups.Where(group => group.Count > 0).Select(group => new Block(
            NameOf(group[0]),
            group[0].StartTime,
            group.Max(segment => segment.EndTime),
            string.Join(' ', group.Select(segment => segment.DisplayText.Trim()))))];
    }

    /// <summary>In capitals, so a section reads apart from the speakers' headings.</summary>
    private static string SectionLine(RecordingSection section) =>
        $"{section.Title.ToUpperInvariant()} · {DurationFormatting.Duration(section.Start)}";

    private static string MomentLine(RecordingMoment moment)
    {
        var heading = $"⚑ {DurationFormatting.Duration(moment.Time)} · {moment.Title}";
        return moment.Note is { } note ? $"{heading}: {note}" : heading;
    }
}
