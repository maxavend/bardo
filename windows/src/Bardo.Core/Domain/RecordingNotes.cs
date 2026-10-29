using System.Text.Json.Serialization;
using Bardo.Resources;
using Bardo.Serialization;

namespace Bardo.Domain;

/// <summary>
/// A point in a recording someone marked while it ran or afterwards: a title and,
/// optionally, a note, like jotting something down during a meeting.
/// </summary>
public sealed record RecordingMoment
{
    public RecordingMoment(double time, string title, string? note = null, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Time = Math.Max(0, time);
        Title = title;
        Note = note?.Trim().NonEmpty();
    }

    [JsonConstructor]
    private RecordingMoment(Guid id, double time, string title, string? note = null) : this(time, title, note, id)
    {
    }

    public Guid Id { get; }
    public double Time { get; }
    public string Title { get; }
    public string? Note { get; }

    /// <summary>The title a moment gets when the person types none, such as "Momento 12:31".</summary>
    public static string DefaultTitle(double time) => Strings.MomentTitle(DurationFormatting.Duration(time));
}

/// <summary>
/// A named part of a recording, from its start until the next section begins. The
/// audio stays one file; sections only name stretches of it.
/// </summary>
public sealed record RecordingSection
{
    public RecordingSection(double start, string title, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Start = Math.Max(0, start);
        Title = title;
    }

    [JsonConstructor]
    private RecordingSection(Guid id, double start, string title) : this(start, title, id)
    {
    }

    public Guid Id { get; }
    public double Start { get; }
    public string Title { get; init; }
}

/// <summary>The moments and sections of one recording, kept in time order.</summary>
public sealed record RecordingNotes
{
    public static RecordingNotes Empty { get; } = new([], []);

    [JsonConstructor]
    public RecordingNotes(EquatableArray<RecordingMoment> moments, EquatableArray<RecordingSection> sections)
    {
        Moments = moments.OrderBy(moment => moment.Time).ToEquatableArray();
        Sections = sections.OrderBy(section => section.Start).ToEquatableArray();
    }

    public EquatableArray<RecordingMoment> Moments { get; }
    public EquatableArray<RecordingSection> Sections { get; }

    [JsonIgnore]
    public bool IsEmpty => Moments.Count == 0 && Sections.Count == 0;

    /// <summary>Adds a moment, titled after its time when <paramref name="title"/> is blank.</summary>
    public (RecordingNotes Notes, RecordingMoment Moment) AddingMoment(double time, string title, string? note)
    {
        var moment = new RecordingMoment(time, title.Trim().NonEmpty() ?? RecordingMoment.DefaultTitle(time), note);
        return (new RecordingNotes([.. Moments, moment], Sections), moment);
    }

    /// <summary>Starts a section at <paramref name="time"/>; the one before it ends there.</summary>
    public (RecordingNotes Notes, RecordingSection Section) AddingSection(double time, string title)
    {
        var section = new RecordingSection(time, title.Trim().NonEmpty() ?? NextSectionTitle);
        return (new RecordingNotes(Moments, [.. Sections, section]), section);
    }

    /// <summary>Retitles a moment and sets its note; a blank title goes back to the default one.</summary>
    public RecordingNotes EditingMoment(Guid id, string title, string? note) =>
        new(Moments.Select(moment => moment.Id != id
            ? moment
            : new RecordingMoment(
                moment.Time,
                title.Trim().NonEmpty() ?? RecordingMoment.DefaultTitle(moment.Time),
                note,
                id)).ToEquatableArray(),
            Sections);

    public RecordingNotes RenamingSection(Guid id, string title)
    {
        if (title.Trim().NonEmpty() is not { } trimmed) return this;
        return new(Moments, Sections.Select(section => section.Id == id ? section with { Title = trimmed } : section).ToEquatableArray());
    }

    public RecordingNotes Updating(RecordingMoment moment) =>
        new(Moments.Select(existing => existing.Id == moment.Id ? moment : existing).ToEquatableArray(), Sections);

    public RecordingNotes Updating(RecordingSection section) =>
        new(Moments, Sections.Select(existing => existing.Id == section.Id ? section : existing).ToEquatableArray());

    public RecordingNotes RemovingMoment(Guid id) =>
        new(Moments.Where(moment => moment.Id != id).ToEquatableArray(), Sections);

    public RecordingNotes RemovingSection(Guid id) =>
        new(Moments, Sections.Where(section => section.Id != id).ToEquatableArray());

    /// <summary>"Sección 2" after the first, so a quick Enter still names each part.</summary>
    [JsonIgnore]
    public string NextSectionTitle => Strings.SectionTitle(Sections.Count + 1);

    /// <summary>Where a section ends: where the next one starts, or the end of the recording.</summary>
    public double? End(RecordingSection section, double? duration) =>
        Sections.FirstOrDefault(next => next.Start > section.Start)?.Start ?? duration;
}

/// <summary>
/// Where moments and sections go among the blocks of a transcript: a section heads the
/// first block it covers, and a moment follows the block during which it was marked.
/// </summary>
public sealed class TranscriptNotePlacement
{
    /// <summary>A section that starts this close before a paragraph still heads it.</summary>
    public const double Tolerance = 1;

    private readonly Dictionary<int, List<RecordingSection>> _sectionsByParagraph = [];
    private readonly Dictionary<int, List<RecordingMoment>> _momentsByParagraph = [];

    public TranscriptNotePlacement(RecordingNotes notes, IReadOnlyList<double> paragraphStarts)
    {
        var leading = new List<RecordingMoment>();
        var trailing = new List<RecordingSection>();
        foreach (var section in notes.Sections)
        {
            var index = FirstIndex(paragraphStarts, start => start >= section.Start - Tolerance);
            if (index is { } found) Add(_sectionsByParagraph, found, section);
            else trailing.Add(section);
        }
        foreach (var moment in notes.Moments)
        {
            var index = LastIndex(paragraphStarts, start => start <= moment.Time);
            if (index is { } found) Add(_momentsByParagraph, found, moment);
            else leading.Add(moment);
        }
        LeadingMoments = leading;
        TrailingSections = trailing;
    }

    public IReadOnlyList<RecordingMoment> LeadingMoments { get; }
    public IReadOnlyList<RecordingSection> TrailingSections { get; }

    public IReadOnlyList<RecordingSection> SectionsBefore(int paragraph) =>
        _sectionsByParagraph.TryGetValue(paragraph, out var sections) ? sections : [];

    public IReadOnlyList<RecordingMoment> MomentsAfter(int paragraph) =>
        _momentsByParagraph.TryGetValue(paragraph, out var moments) ? moments : [];

    private static void Add<T>(Dictionary<int, List<T>> groups, int index, T item)
    {
        if (!groups.TryGetValue(index, out var list)) groups[index] = list = [];
        list.Add(item);
    }

    private static int? FirstIndex(IReadOnlyList<double> values, Func<double, bool> predicate)
    {
        for (var index = 0; index < values.Count; index++)
            if (predicate(values[index])) return index;
        return null;
    }

    private static int? LastIndex(IReadOnlyList<double> values, Func<double, bool> predicate)
    {
        for (var index = values.Count - 1; index >= 0; index--)
            if (predicate(values[index])) return index;
        return null;
    }
}
