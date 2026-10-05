using System.Globalization;
using System.Text.Json;
using static TokenCat.TokenSource;

namespace TokenCat;

// Telemetry.swift `TelemetryDiagnosticEntry`, `TelemetryDiagnostics`, `TelemetryRecord` and `TelemetryDecoder`: OTLP/HTTP JSON
// → readings. Only model/request identifiers and explicitly measured numbers survive; never bodies or attribute values.

public sealed record TelemetryDiagnosticEntry
{
    public required string Signal { get; init; }
    public string? ResourceServiceName { get; init; }
    public string? MetricName { get; init; }
    public string? Unit { get; init; }
    /// The service/name/unit are eligible; usable numeric points are counted separately.
    public bool Recognized { get; init; }
    /// Unrecognized services only: a span or event name and the attribute keys seen with it
    /// (bounded ASCII, never values), so a mapping can be added from evidence later.
    public string? Name { get; init; }
    public IReadOnlyList<string>? AttributeKeys { get; init; }

    internal bool SameSlot(TelemetryDiagnosticEntry other) => Signal == other.Signal && ResourceServiceName == other.ResourceServiceName
        && MetricName == other.MetricName && Unit == other.Unit && Recognized == other.Recognized && Name == other.Name;

    internal TelemetryDiagnosticEntry Absorb(TelemetryDiagnosticEntry other) => other.AttributeKeys is null ? this : this with
    {
        AttributeKeys = [.. (AttributeKeys ?? []).Union(other.AttributeKeys).Order(StringComparer.Ordinal).Take(TelemetryCollector.MaximumDiagnosticKeys)],
    };
}

public sealed record TelemetryDiagnostics(IReadOnlyDictionary<string, int> ReceivedBatches, IReadOnlyDictionary<string, int> DecodedReadings,
    IReadOnlyList<TelemetryDiagnosticEntry> Entries);

sealed record TelemetryRecord(TelemetryReading Reading, int DurationPriority = 0, int IntervalPriority = 0)
{
    public bool HasRate => new TokenSpeedMeasurement(Reading).TokensPerSecond is not null;

    public string Key
    {
        get
        {
            var scope = $"{Reading.Provider.Id}|{Reading.SessionID}|";
            if (Reading.RequestID is { } request) return scope + "request|" + request;
            // No request ID means that only an identical timestamped observation deduplicates.
            return scope + $"observation|{Reading.AgentID}|{Reading.Model}|{Reading.At.UtcTicks}";
        }
    }

    public TelemetryRecord Merge(TelemetryRecord incoming)
    {
        var (reading, next) = (Reading, incoming.Reading);
        var (durationPriority, intervalPriority) = (DurationPriority, IntervalPriority);
        reading = reading with { AgentID = reading.AgentID ?? next.AgentID, Model = reading.Model ?? next.Model, At = reading.At > next.At ? reading.At : next.At };
        if (next.OutputTokens is { } tokens) reading = reading with { OutputTokens = Math.Max(reading.OutputTokens ?? 0, tokens) };
        if (next.RequestDurationMs is { } duration && (reading.RequestDurationMs is null || incoming.DurationPriority > durationPriority))
        {
            reading = reading with { RequestDurationMs = duration, RequestDurationIncludesRetries = next.RequestDurationIncludesRetries };
            durationPriority = incoming.DurationPriority;
        }
        if (next.TtftMs is { } ttft) reading = reading with { TtftMs = ttft };
        if (next.ServerTokenIntervalMs is { } interval && (reading.ServerTokenIntervalMs is null || incoming.IntervalPriority > intervalPriority))
        {
            reading = reading with
            {
                ServerTokenIntervalMs = interval, ServerTokenIntervalMetric = next.ServerTokenIntervalMetric,
                ServerTokenIntervalSampleCount = next.ServerTokenIntervalSampleCount, MetricWindowStartedAt = next.MetricWindowStartedAt,
            };
            intervalPriority = incoming.IntervalPriority;
        }
        reading = reading with { ServerInferenceMs = next.ServerInferenceMs ?? reading.ServerInferenceMs };
        return new(reading, durationPriority, intervalPriority);
    }
}

static class TelemetryDecoder
{
    const string InvalidMetadata = "__invalid_metadata__";
    static readonly HashSet<string> AllowedKeys = ["service.name", "session.id", "session_id", "conversation.id", "conversation_id",
        "agent.id", "agent_id", "model", "gen_ai.request.model", "request_id", "request.id", "gen_ai.response.id", "event.name",
        "event_name", "event.timestamp", "duration_ms", "ttft_ms", "output_tokens", "success"];
    static readonly Dictionary<string, int> MetricKinds = new()
    {
        ["codex.responses_api_engine_service_tbt.duration_ms"] = 1,
        ["codex.responses_api_engine_iapi_tbt.duration_ms"] = 2,
        ["codex.responses_api_inference_time.duration_ms"] = 3,
    };

    static (string Resource, string Scope, string Signal) Keys(string path) => path switch
    {
        "/v1/logs" => ("resourceLogs", "scopeLogs", "logs"),
        "/v1/metrics" => ("resourceMetrics", "scopeMetrics", "metrics"),
        _ => ("resourceSpans", "scopeSpans", "traces"),
    };

    /// Null when the batch does not have the OTLP shape for `path`; an empty object is an empty batch.
    public static List<TelemetryRecord>? Decode(JsonElement root, string path)
    {
        if (path is not ("/v1/logs" or "/v1/metrics" or "/v1/traces")) return null;
        var (resourceKey, scopeKey, _) = Keys(path);
        var empty = !root.EnumerateObject().Any();
        if (!empty && root.Field(resourceKey) is null) return null;
        if ((empty ? [] : Objects(root.Field(resourceKey))) is not { } resources) return null;
        var result = new List<TelemetryRecord>();
        foreach (var resource in resources)
        {
            var resourceAttributes = Attributes(resource.Field("resource")?.Field("attributes"));
            if (Objects(resource.Field(scopeKey)) is not { } scopes) return null;
            foreach (var scope in scopes)
            {
                if (path == "/v1/logs")
                {
                    if (Objects(scope.Field("logRecords")) is not { } logs) return null;
                    foreach (var log in logs)
                    {
                        var attrs = Merging(resourceAttributes, Attributes(log.Field("attributes")));
                        if (attrs.GetValueOrDefault("success") is false) continue;
                        var body = log.Field("body")?.Field("stringValue")?.Text;
                        var name = attrs.GetValueOrDefault("event.name") as string ?? attrs.GetValueOrDefault("event_name") as string ?? body;
                        if (name is not ("api_request" or "claude_code.api_request") || Source(resourceAttributes, name) != Claude
                            || Integer(attrs.GetValueOrDefault("output_tokens")) is not { } tokens
                            || Number(attrs.GetValueOrDefault("duration_ms")) is not { } duration || duration <= 0) continue;
                        var reading = Metadata(attrs, Claude, Timestamp(log.Field("timeUnixNano"), attrs)) with { OutputTokens = tokens, RequestDurationMs = duration };
                        result.Add(new(reading, DurationPriority: 2));
                    }
                }
                else if (path == "/v1/traces")
                {
                    if (Objects(scope.Field("spans")) is not { } spans) return null;
                    foreach (var span in spans)
                    {
                        if (span.Field("name")?.Text != "claude_code.llm_request" || Source(resourceAttributes, "claude_code.llm_request") != Claude) continue;
                        var attrs = Merging(resourceAttributes, Attributes(span.Field("attributes")));
                        if (attrs.GetValueOrDefault("success") is false) continue;
                        if (span.Field("status") is { ValueKind: JsonValueKind.Object } status && Integer(status.Field("code")) == 2) continue;
                        var reading = Metadata(attrs, Claude, Timestamp(span.Field("endTimeUnixNano"), attrs)) with
                        {
                            OutputTokens = Integer(attrs.GetValueOrDefault("output_tokens")),
                            RequestDurationMs = Number(attrs.GetValueOrDefault("duration_ms")) is { } duration && duration > 0 ? duration : null,
                            RequestDurationIncludesRetries = true,
                            TtftMs = Number(attrs.GetValueOrDefault("ttft_ms")),
                        };
                        if (reading.OutputTokens is null && reading.TtftMs is null) continue;
                        result.Add(new(reading, DurationPriority: 1));
                    }
                }
                else
                {
                    if (Objects(scope.Field("metrics")) is not { } metrics) return null;
                    foreach (var metric in metrics)
                    {
                        if (metric.Field("name")?.Text is not { } name || !MetricKinds.TryGetValue(name, out var kind) || Source(resourceAttributes, name) != Codex) continue;
                        if (metric.Field("unit")?.Text is { Length: > 0 } unit && unit != "ms") continue;
                        var histogram = metric.Field("histogram") is { ValueKind: JsonValueKind.Object } h ? h : (JsonElement?)null;
                        var gauge = metric.Field("gauge") is { ValueKind: JsonValueKind.Object } g ? g : (JsonElement?)null;
                        if (Objects((histogram ?? gauge)?.Field("dataPoints")) is not { } points) continue;
                        foreach (var point in points)
                        {
                            double? value;
                            int count;
                            if (histogram is not null)
                            {
                                if (Integer(point.Field("count")) is not { } sampleCount || sampleCount <= 0
                                    || Number(point.Field("sum")) is not { } sum || sum <= 0) continue;
                                count = sampleCount;
                                value = sum / sampleCount;
                            }
                            else
                            {
                                count = 1;
                                value = Number(point.Field("asDouble") ?? point.Field("asInt"));
                            }
                            if (value is not > 0) continue;
                            var attrs = Merging(resourceAttributes, Attributes(point.Field("attributes")));
                            var reading = Metadata(attrs, Codex, Timestamp(point.Field("timeUnixNano"), attrs));
                            // Multiple server observations are valid model-level measurements,
                            // never an individual session/request's generation rate.
                            if (count > 1) reading = reading with { SessionID = null, AgentID = null, RequestID = null };
                            reading = reading with { MetricWindowStartedAt = NanoDate(point.Field("startTimeUnixNano")) };
                            reading = kind == 3 ? reading with { ServerInferenceMs = value }
                                : reading with { ServerTokenIntervalMs = value, ServerTokenIntervalMetric = name, ServerTokenIntervalSampleCount = count };
                            result.Add(new(reading, IntervalPriority: kind == 1 ? 2 : 1));
                        }
                    }
                }
            }
        }
        return result;
    }

    /// Clients named by the batch's resources, whether or not any record decodes.
    public static HashSet<TokenSource> Providers(JsonElement root, string path) =>
        [.. (Objects(root.Field(Keys(path).Resource)) ?? [])
            .Select(resource => Source(Attributes(resource.Field("resource")?.Field("attributes")), null)).OfType<TokenSource>()];

    static TokenSource? Source(Dictionary<string, object> attrs, string? fallback)
    {
        if (attrs.GetValueOrDefault("service.name") is string service)
            return service switch
            {
                // CLI services and the exact service observed in Claude desktop OTLP.
                "claude-code" or "claude_code" or "claude-code-desktop" => Claude,
                // Fixed first-party surfaces present in the bundled 0.160.0 CLI's
                // service-name classification; unknown/custom services stay rejected.
                "codex" or "codex-cli" or "codex_cli_rs" or "codex_exec" or "codex-app-server" or "codex_desktop" or "codex-tui"
                    or "codex_vscode" or "codex_mcp_server" or "codex_sdk_ts" or "codex-app-server-sdk" or "Codex Desktop" => Codex,
                _ => null,
            };
        if (fallback?.StartsWith("claude_code.", StringComparison.Ordinal) == true) return Claude;
        if (fallback?.StartsWith("codex.", StringComparison.Ordinal) == true) return Codex;
        return null;
    }

    /// Same-slot entries combine their attribute keys; the newest slot moves to the end.
    public static void Merge(TelemetryDiagnosticEntry entry, List<TelemetryDiagnosticEntry> entries)
    {
        var index = entries.FindIndex(existing => existing.SameSlot(entry));
        if (index >= 0)
        {
            entry = entries[index].Absorb(entry);
            entries.RemoveAt(index);
        }
        entries.Add(entry);
        if (entries.Count > TelemetryCollector.MaximumDiagnostics) entries.RemoveRange(0, entries.Count - TelemetryCollector.MaximumDiagnostics);
    }

    /// Only bounded signal/service/metric/unit metadata is retained, never log bodies or
    /// attribute values. Unrecognized log/trace services add span or event names and keys.
    public static List<TelemetryDiagnosticEntry> Diagnostics(JsonElement root, string path)
    {
        var (resourceKey, scopeKey, signal) = Keys(path);
        var result = new List<TelemetryDiagnosticEntry>();
        static string? Bounded(object? value) => value switch
        {
            null => null,
            string text => text.Length <= 256 && text.All(c => c is >= ' ' and <= '~') ? text : InvalidMetadata,
            JsonElement { ValueKind: JsonValueKind.String } element => Bounded(element.GetString()),
            _ => InvalidMetadata,
        };
        // Span/event names and attribute keys are code-defined identifiers; anything else is dropped.
        static bool IsName(string text) => text.Length is >= 1 and <= 128 && text.All(c => char.IsAsciiLetterOrDigit(c) || "._-:/".Contains(c));
        foreach (var resource in Objects(root.Field(resourceKey)) ?? [])
        {
            var resourceAttributes = Attributes(resource.Field("resource")?.Field("attributes"));
            var service = Bounded(resourceAttributes.GetValueOrDefault("service.name"));
            if (signal != "metrics")
            {
                var recognized = Source(resourceAttributes, null) == Claude;
                var described = false;
                List<JsonElement> scopes = recognized ? [] : Objects(resource.Field(scopeKey)) ?? [];
                foreach (var scope in scopes)
                {
                    foreach (var item in Objects(scope.Field(signal == "logs" ? "logRecords" : "spans")) ?? [])
                    {
                        var raw = Objects(item.Field("attributes")) ?? [];
                        var keys = raw.Select(attribute => attribute.Field("key")?.Text).OfType<string>().Where(key => IsName(key) && key.Length <= 64)
                            .Distinct().Order(StringComparer.Ordinal).Take(TelemetryCollector.MaximumDiagnosticKeys).ToList();
                        // Codex log events carry their name in event.name; bodies are never read.
                        var label = signal == "traces" ? item.Field("name")?.Text
                            : raw.Where(attribute => attribute.Field("key")?.Text is "event.name" or "event_name")
                                .Select(attribute => attribute.Field("value")?.Field("stringValue")?.Text).FirstOrDefault();
                        Merge(new() { Signal = signal, ResourceServiceName = service, Recognized = false,
                            Name = label is null ? null : IsName(label) ? label : InvalidMetadata, AttributeKeys = keys }, result);
                        described = true;
                    }
                }
                if (!described) Merge(new() { Signal = signal, ResourceServiceName = service, Recognized = recognized }, result);
                continue;
            }
            foreach (var scope in Objects(resource.Field(scopeKey)) ?? [])
            {
                foreach (var metric in Objects(scope.Field("metrics")) ?? [])
                {
                    var name = metric.Field("name")?.Text;
                    var unit = metric.Field("unit")?.Text;
                    var recognized = name is not null && MetricKinds.ContainsKey(name) && Source(resourceAttributes, name) == Codex && unit is null or "" or "ms";
                    Merge(new() { Signal = signal, ResourceServiceName = service, MetricName = Bounded(metric.Field("name")),
                        Unit = Bounded(metric.Field("unit")), Recognized = recognized }, result);
                }
            }
        }
        return result;
    }

    /// Swift's `as? [[String: Any]]`: null unless an array whose every item is an object.
    static List<JsonElement>? Objects(JsonElement? value) =>
        value is { ValueKind: JsonValueKind.Array } array && array.EnumerateArray().All(item => item.ValueKind == JsonValueKind.Object)
            ? [.. array.EnumerateArray()] : null;

    static Dictionary<string, object> Merging(Dictionary<string, object> resource, Dictionary<string, object> record)
    {
        var merged = new Dictionary<string, object>(resource);
        foreach (var (key, value) in record) merged[key] = value;
        return merged;
    }

    /// Whitelisted keys only: strings, booleans (`success`) and finite non-negative numbers.
    static Dictionary<string, object> Attributes(JsonElement? value)
    {
        var result = new Dictionary<string, object>();
        foreach (var entry in Objects(value) ?? [])
        {
            if (entry.Field("key")?.Text is not { } key || !AllowedKeys.Contains(key)) continue;
            if (key == "service.name")
            {
                // An explicit unrecognized service must not disappear and activate
                // the absent-resource fallback. This value never enters a reading.
                var service = entry.Field("value")?.Field("stringValue")?.Text;
                result[key] = service is not null && System.Text.Encoding.UTF8.GetByteCount(service) <= 256 ? service : "__invalid_service__";
                continue;
            }
            if (entry.Field("value") is not { ValueKind: JsonValueKind.Object } wrapped) continue;
            if (key == "success" && wrapped.Field("boolValue")?.Bool is { } flag) result[key] = flag;
            else if (wrapped.Field("stringValue")?.Text is { } text)
            {
                if (key == "event.timestamp")
                {
                    if (text.Length <= 64) result[key] = text;
                    else result.Remove(key);
                }
                else if (Identifier(text) is { } safe) result[key] = safe;
            }
            else if (Number(wrapped.Field("intValue") ?? wrapped.Field("doubleValue")) is { } number) result[key] = number;
        }
        return result;
    }

    static TelemetryReading Metadata(Dictionary<string, object> attrs, TokenSource source, DateTimeOffset at)
    {
        string? Text(params string[] names) => names.Select(name => attrs.GetValueOrDefault(name) as string).FirstOrDefault(text => text is not null);
        return new()
        {
            Provider = source, At = at,
            SessionID = Text("session.id", "session_id", "conversation.id", "conversation_id"), AgentID = Text("agent_id", "agent.id"),
            Model = Text("model", "gen_ai.request.model"), RequestID = Text("request_id", "request.id", "gen_ai.response.id"),
        };
    }

    static string? Identifier(string value) =>
        value.Length is > 0 and <= 256 && value.All(c => char.IsAsciiLetterOrDigit(c) || "-_.:/@".Contains(c)) ? value : null;

    /// Finite, non-negative; JSON numbers or numeric strings of at most 32 characters (OTLP writes 64-bit integers as strings).
    static double? Number(object? value)
    {
        static double? Parse(string text) => text.Length <= 32 && double.TryParse(text,
            NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
        var parsed = value switch
        {
            double number => number,
            string text => Parse(text),
            JsonElement element => element.Number ?? (element.Text is { } text ? Parse(text) : null),
            _ => null,
        };
        return parsed is { } finite && double.IsFinite(finite) && finite >= 0 ? finite : null;
    }

    static int? Integer(object? value) => Number(value) is { } number && Math.Truncate(number) == number && number <= int.MaxValue ? (int)number : null;

    static DateTimeOffset Timestamp(JsonElement? value, Dictionary<string, object> attrs) =>
        NanoDate(value) ?? (attrs.GetValueOrDefault("event.timestamp") is string text ? Iso8601(text) : null) ?? DateTimeOffset.UtcNow;

    static readonly long MaximumTicks = (DateTimeOffset.MaxValue - DateTimeOffset.UnixEpoch).Ticks;

    static DateTimeOffset? NanoDate(object? value) =>
        Number(value) is { } nanoseconds && nanoseconds > 0 && nanoseconds / 100 < MaximumTicks
            ? DateTimeOffset.UnixEpoch.AddTicks((long)(nanoseconds / 100)) : null;

    /// ISO8601DateFormatter with `.withInternetDateTime` (± fractional seconds): `Z` or `±hh:mm` required (rule 4).
    static readonly string[] IsoFormats = [.. from digits in Enumerable.Range(0, 8) from zone in new[] { "'Z'", "zzz" }
        select "yyyy-MM-dd'T'HH:mm:ss" + (digits > 0 ? "." + new string('f', digits) : "") + zone];

    static DateTimeOffset? Iso8601(string text) =>
        DateTimeOffset.TryParseExact(text, IsoFormats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : null;
}
