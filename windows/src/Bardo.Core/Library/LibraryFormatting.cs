using System.Globalization;
using Bardo.Domain;
using Bardo.Resources;
using Bardo.Serialization;

namespace Bardo.Library;

/// <summary>The sections of the Library sidebar.</summary>
public enum LibrarySection
{
    All,
    Recorded,
    Imported,
}

public static class LibrarySectionExtensions
{
    public static bool Contains(this LibrarySection section, Recording recording) => section switch
    {
        LibrarySection.All => true,
        LibrarySection.Recorded => !recording.Sources.Contains(AudioSource.ImportedFile),
        LibrarySection.Imported => recording.Sources.Contains(AudioSource.ImportedFile),
        _ => false,
    };
}

public static class LibraryFormatting
{
    /// <summary>
    /// The title someone gave the recording, or "Grabación del 28 oct 12:31" when it only
    /// has a technical one.
    /// </summary>
    public static string RecordingTitle(Recording recording, CultureInfo? culture = null)
    {
        var title = recording.Title.Trim();
        if (title.Length > 0 && !IsTechnicalTitle(title, recording.Id)) return title;
        culture ??= CultureInfo.CurrentCulture;
        var date = recording.CreatedAt.ToLocalTime();
        return Strings.RecordingFrom(date.ToString("d MMM, ", culture) + date.ToString(culture.DateTimeFormat.ShortTimePattern, culture));
    }

    /// <summary>
    /// The compact date a mail list shows: the time for today, then "Yesterday", the
    /// weekday for the past week and a short date before that.
    /// </summary>
    public static string ListDate(DateTimeOffset date, DateTimeOffset now, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        var local = date.ToLocalTime();
        var today = now.ToLocalTime();
        // Whole calendar days between the two dates, measured against `now`.
        var days = (today.Date - local.Date).Days;
        switch (days)
        {
            case 0:
                return local.ToString(culture.DateTimeFormat.ShortTimePattern, culture);
            case 1:
                return Strings.Yesterday;
            case > 1 and < 7:
                return culture.TextInfo.ToTitleCase(local.ToString("dddd", culture));
        }
        return local.Year == today.Year
            ? local.ToString("d MMM", culture)
            : local.ToString("d MMM yyyy", culture);
    }

    /// <summary>"Micrófono + Audio del sistema", in the order macOS lists them.</summary>
    public static string Sources(IEnumerable<AudioSource> sources)
    {
        var names = sources
            .Distinct()
            .OrderBy(source => source switch
            {
                AudioSource.ImportedFile => 0,
                AudioSource.Microphone => 1,
                _ => 2,
            })
            .Select(source => source switch
            {
                AudioSource.Microphone => Strings.SourceMicrophone,
                AudioSource.SystemAudio => Strings.SourceSystemAudio,
                _ => Strings.SourceImportedFile,
            })
            .ToList();
        return names.Count == 0 ? Strings.UnknownSource : string.Join(" + ", names);
    }

    private static bool IsTechnicalTitle(string title, Guid id)
    {
        var uuid = id.ToUuidString();
        return title.Contains(uuid, StringComparison.OrdinalIgnoreCase)
            || (title.Contains("Recording ", StringComparison.OrdinalIgnoreCase)
                && title.Contains(uuid[..8], StringComparison.Ordinal));
    }
}

/// <summary>
/// Library search: any of the query's words, ignoring case and accents, in a recording's
/// title, its participants' names or what was said.
/// </summary>
public static class LibrarySearch
{
    private static readonly CompareInfo Comparer = CultureInfo.InvariantCulture.CompareInfo;
    private const CompareOptions Options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;

    public static IReadOnlyList<string> Terms(string query) =>
        query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    public static bool Contains(string text, string query)
    {
        var terms = Terms(query);
        return terms.Count > 0 && terms.Any(term => Comparer.IndexOf(text, term, Options) >= 0);
    }

    public static bool Matches(Recording recording, Transcript? transcript, string query)
    {
        if (Terms(query).Count == 0) return true;
        if (Contains(LibraryFormatting.RecordingTitle(recording), query)) return true;
        if (transcript is null) return false;
        return transcript.Speakers.Any(speaker => Contains(transcript.DisplayName(speaker), query))
            || Contains(transcript.Text, query);
    }
}
