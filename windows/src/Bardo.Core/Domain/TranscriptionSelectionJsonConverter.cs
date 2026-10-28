using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bardo.Domain;

/// <summary>
/// Reads a selection the way Bardo for macOS does: an unknown or missing backend is
/// Whisper, and any Whisper model other than Large is Turbo.
/// </summary>
internal sealed class TranscriptionSelectionJsonConverter : JsonConverter<TranscriptionSelection>
{
    private const string BackendKey = "backend";
    private const string ModelIdKey = "modelID";

    public override TranscriptionSelection Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new JsonException("Expected a transcription selection.");

        var backend = OptionalString(root, BackendKey);
        var modelId = OptionalString(root, ModelIdKey);
        return backend switch
        {
            "appleSpeech" => new(TranscriptionBackend.AppleSpeech, modelId ?? TranscriptionSelection.AppleModelId),
            "whisperKit" when modelId == TranscriptionSelection.LargeModelId =>
                new(TranscriptionBackend.WhisperKit, TranscriptionSelection.LargeModelId),
            _ => new(TranscriptionBackend.WhisperKit, TranscriptionSelection.TurboModelId),
        };
    }

    public override void Write(Utf8JsonWriter writer, TranscriptionSelection value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WritePropertyName(BackendKey);
        JsonSerializer.Serialize(writer, value.Backend, options);
        writer.WriteString(ModelIdKey, value.ModelId);
        writer.WriteEndObject();
    }

    private static string? OptionalString(JsonElement root, string key) =>
        root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
