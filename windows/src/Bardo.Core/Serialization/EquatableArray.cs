using System.Collections;
using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bardo.Serialization;

/// <summary>
/// An immutable list compared by its elements, so records that hold one keep the value
/// semantics Swift structs have. Serialized as a plain JSON array.
/// </summary>
[JsonConverter(typeof(EquatableArrayJsonConverterFactory))]
[CollectionBuilder(typeof(EquatableArray), nameof(EquatableArray.Create))]
public readonly struct EquatableArray<T> : IReadOnlyList<T>, IEquatable<EquatableArray<T>>
{
    private readonly ImmutableArray<T> _items;

    public EquatableArray(IEnumerable<T> items)
    {
        _items = [.. items];
    }

    private EquatableArray(ImmutableArray<T> items)
    {
        _items = items;
    }

    internal static EquatableArray<T> From(ImmutableArray<T> items) => new(items);

    private ImmutableArray<T> Items => _items.IsDefault ? [] : _items;

    public int Count => Items.Length;

    public T this[int index] => Items[index];

    public bool Equals(EquatableArray<T> other) => Items.SequenceEqual(other.Items);

    public override bool Equals(object? obj) => obj is EquatableArray<T> other && Equals(other);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var item in Items) hash.Add(item);
        return hash.ToHashCode();
    }

    public ImmutableArray<T>.Enumerator GetEnumerator() => Items.GetEnumerator();

    IEnumerator<T> IEnumerable<T>.GetEnumerator() => ((IEnumerable<T>)Items).GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => ((IEnumerable)Items).GetEnumerator();

    public static bool operator ==(EquatableArray<T> left, EquatableArray<T> right) => left.Equals(right);

    public static bool operator !=(EquatableArray<T> left, EquatableArray<T> right) => !left.Equals(right);

    public static implicit operator EquatableArray<T>(T[] items) => new(items);

    public static implicit operator EquatableArray<T>(List<T> items) => new(items);

    public static implicit operator EquatableArray<T>(ImmutableArray<T> items) => new(items);

    public override string ToString() => $"[{string.Join(", ", Items)}]";
}

public static class EquatableArray
{
    public static EquatableArray<T> Create<T>(ReadOnlySpan<T> items) => EquatableArray<T>.From(ImmutableArray.Create(items));

    public static EquatableArray<T> ToEquatableArray<T>(this IEnumerable<T> items) => new(items);
}

internal sealed class EquatableArrayJsonConverterFactory : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) =>
        typeToConvert.IsGenericType && typeToConvert.GetGenericTypeDefinition() == typeof(EquatableArray<>);

    public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options)
    {
        var elementType = typeToConvert.GetGenericArguments()[0];
        return (JsonConverter)Activator.CreateInstance(
            typeof(EquatableArrayJsonConverter<>).MakeGenericType(elementType))!;
    }

    private sealed class EquatableArrayJsonConverter<T> : JsonConverter<EquatableArray<T>>
    {
        public override EquatableArray<T> Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            new(JsonSerializer.Deserialize<T[]>(ref reader, options) ?? throw new JsonException("Expected an array."));

        public override void Write(Utf8JsonWriter writer, EquatableArray<T> value, JsonSerializerOptions options)
        {
            writer.WriteStartArray();
            foreach (var item in value) JsonSerializer.Serialize(writer, item, options);
            writer.WriteEndArray();
        }
    }
}
