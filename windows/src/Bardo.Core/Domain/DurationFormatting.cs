using System.Globalization;
using Bardo.Resources;

namespace Bardo.Domain;

public static class DurationFormatting
{
    public static string Duration(double? duration) =>
        duration is { } value ? Duration(value) : Strings.UnknownDuration;

    /// <summary>"12:31", or "1:02:05" past an hour.</summary>
    public static string Duration(double duration)
    {
        var seconds = Math.Max(0, (int)Math.Round(duration, MidpointRounding.AwayFromZero));
        var hours = seconds / 3_600;
        var minutes = seconds % 3_600 / 60;
        var remainingSeconds = seconds % 60;
        return hours > 0
            ? string.Create(CultureInfo.InvariantCulture, $"{hours}:{minutes:00}:{remainingSeconds:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{minutes}:{remainingSeconds:00}");
    }
}

internal static class StringExtensions
{
    public static string? NonEmpty(this string value) => value.Length == 0 ? null : value;

    public static string? NonEmptyTrimmed(this string? value) => value?.Trim().NonEmpty();
}
