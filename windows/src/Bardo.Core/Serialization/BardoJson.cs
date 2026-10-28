using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bardo.Serialization;

/// <summary>
/// JSON that reads and writes what Bardo for macOS keeps on disk, so one Library opens on
/// either platform: camel-case keys, enum cases by name, upper-case UUIDs, absent
/// optionals left out, and dates as Swift's <c>JSONEncoder</c> writes them by default.
/// </summary>
public static class BardoJson
{
    public static JsonSerializerOptions Options { get; } = CreateOptions();

    public static byte[] Serialize<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T Deserialize<T>(ReadOnlySpan<byte> json) =>
        JsonSerializer.Deserialize<T>(json, Options) ?? throw new JsonException($"Expected {typeof(T).Name}, found null.");

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = true,
            // A missing required key makes the document invalid, as it does for Swift's
            // synthesized decoders; optionals may be absent.
            RespectNullableAnnotations = true,
            RespectRequiredConstructorParameters = true,
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        options.Converters.Add(new UpperCaseGuidConverter());
        options.Converters.Add(new ReferenceDateConverter());
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }

    /// <summary>UUIDs as <c>UUID.uuidString</c> writes them, which also names folders.</summary>
    private sealed class UpperCaseGuidConverter : JsonConverter<Guid>
    {
        public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            Guid.TryParseExact(reader.GetString(), "D", out var value)
                ? value
                : throw new JsonException("Expected a UUID.");

        public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToUuidString());
    }

    /// <summary>Seconds since 1 January 2001, Swift's default <c>Date</c> encoding.</summary>
    private sealed class ReferenceDateConverter : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            BardoTime.FromSecondsSinceReferenceDate(reader.GetDouble());

        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
            writer.WriteNumberValue(BardoTime.ToSecondsSinceReferenceDate(value));
    }
}

/// <summary>
/// Dates as Bardo stores them: seconds in a double, kept to the microsecond so a date
/// survives being written and read back on either platform.
/// </summary>
public static class BardoTime
{
    private static readonly DateTimeOffset UnixEpoch = DateTimeOffset.UnixEpoch;
    private static readonly DateTimeOffset ReferenceDate = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public static DateTimeOffset Now => Normalize(DateTimeOffset.UtcNow);

    public static DateTimeOffset Normalize(DateTimeOffset date) => FromSecondsSince1970(ToSecondsSince1970(date));

    public static DateTimeOffset FromSecondsSince1970(double seconds) => FromSeconds(UnixEpoch, seconds);

    public static double ToSecondsSince1970(DateTimeOffset date) => ToSeconds(UnixEpoch, date);

    public static DateTimeOffset FromSecondsSinceReferenceDate(double seconds) => FromSeconds(ReferenceDate, seconds);

    public static double ToSecondsSinceReferenceDate(DateTimeOffset date) => ToSeconds(ReferenceDate, date);

    private static DateTimeOffset FromSeconds(DateTimeOffset origin, double seconds)
    {
        if (!double.IsFinite(seconds)) throw new JsonException("A date must be a finite number of seconds.");
        var microseconds = (long)Math.Round(seconds * 1e6, MidpointRounding.AwayFromZero);
        return origin.AddTicks(microseconds * (TimeSpan.TicksPerMillisecond / 1000));
    }

    private static double ToSeconds(DateTimeOffset origin, DateTimeOffset date)
    {
        var ticks = date.UtcTicks - origin.UtcTicks;
        var microseconds = Math.Round(ticks / 10.0, MidpointRounding.AwayFromZero);
        return microseconds / 1e6;
    }
}

public static class GuidExtensions
{
    /// <summary>The upper-case form <c>UUID.uuidString</c> gives, used in JSON and folder names.</summary>
    public static string ToUuidString(this Guid id) => id.ToString("D", CultureInfo.InvariantCulture).ToUpperInvariant();
}
