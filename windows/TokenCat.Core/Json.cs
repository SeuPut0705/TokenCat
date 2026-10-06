using System.Buffers;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace TokenCat;

/// All JSON in and out goes through here (DESIGN §6.2 rule 3): System.Text.Json's defaults differ from Foundation's.
public static class Json
{
    /// Swift Codable's shape: camelCase stored properties (`sessionID`), raw-value enums (`busyTokenCat`), nil fields omitted.
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = true,
        NewLine = "\n", // the default is Environment.NewLine: CRLF on Windows
        // The default writes 홍길동 and & ' + < > as \uXXXX. ponytail: characters outside the BMP (emoji) are still escaped as
        // surrogate pairs; the value is unchanged, only the bytes differ. A custom encoder if a user ever minds.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// Windows editors and PowerShell 5.1 write one; Swift's JSONSerialization accepts it, JsonDocument throws.
    public static ReadOnlySpan<byte> StripBom(ReadOnlySpan<byte> bytes) =>
        bytes.StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? bytes[3..] : bytes;

    /// Foundation nests about 512 levels; the default 64 would drop a deep tool input or a whole batch.
    public static readonly JsonDocumentOptions Depth = new() { MaxDepth = 512 };

    /// `try? JSONSerialization.jsonObject(with:)`: null when the bytes are not JSON.
    public static JsonElement? Parse(ReadOnlySpan<byte> bytes)
    {
        try
        {
            using var document = JsonDocument.Parse(StripBom(bytes).ToArray(), Depth);
            return document.RootElement.Clone();
        }
        catch (JsonException) { return null; }
    }

    /// For edits (the Claude settings.json rewrite, SettingsStore): null when the bytes are not JSON or repeat a key at any
    /// depth. Readers disagree on which copy counts (Node keeps the last), so a rewrite could drop the one in effect.
    public static JsonNode? ParseNode(ReadOnlySpan<byte> bytes)
    {
        try { return JsonNode.Parse(StripBom(bytes), documentOptions: Depth with { AllowDuplicateProperties = false }); }
        catch (JsonException) { return null; }
    }

    /// `prettyPrinted + sortedKeys + withoutEscapingSlashes`: 2-space indent, LF, ordinal key order, numbers byte-for-byte
    /// as read (`0.10` stays `0.10`), unescaped text, trailing newline.
    public static byte[] Write(JsonElement value)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions)) WriteSorted(writer, value);
        return [.. buffer.WrittenSpan, (byte)'\n'];
    }

    public static byte[] Write(JsonNode? value)
    {
        using var document = JsonDocument.Parse(value?.ToJsonString() ?? "null");
        return Write(document.RootElement);
    }

    /// A model in Codable form through the same writer (`--diagnose`, `/v1/readings`, stored values).
    public static byte[] Serialize<T>(T value) => Write(JsonSerializer.SerializeToElement(value, Options));

    static void WriteSorted(Utf8JsonWriter writer, JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteSorted(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in value.EnumerateArray()) WriteSorted(writer, item);
                writer.WriteEndArray();
                break;
            default:
                value.WriteTo(writer); // a number is written from its raw bytes, so 0.10 and 1e2 stay as they are
                break;
        }
    }

    // Swift's `as? [String: Any]`, `as? String` and `number(_:)` casts, chainable: root.Field("a")?.Field("b")?.Number.
    extension(JsonElement element)
    {
        public JsonElement? Field(string key) =>
            element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) ? value : null;

        /// Finite numbers only; booleans and numeric strings are not numbers (Telemetry.swift `number`).
        public double? Number =>
            element.ValueKind == JsonValueKind.Number && element.TryGetDouble(out var value) && double.IsFinite(value) ? value : null;

        public string? Text => element.ValueKind == JsonValueKind.String ? element.GetString() : null;

        public bool? Bool => element.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };
    }
}
