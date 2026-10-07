using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TokenCat;

/// KimiLog.swift: Kimi Code (Moonshot AI), the same runtime inside the Kimi desktop app (Kimi Work), and the archived kimi-cli.
/// - Kimi Code: `<KIMI_CODE_HOME | %USERPROFILE%\.kimi-code>\sessions\<wd_slug_hash>\<session>\agents\<agent>\wire.jsonl`, one
///   append-only journal per agent (`main`; subagents `agent-0`, …) beside `state.json`. Lines `{"type", …payload, "time" (ms)}`.
///   Turn: `turn.prompt` → `turn.ended` (`completed`, else interrupted; `durationMs` is the turn's duration); `tool.call` →
///   `tool.result` by `toolCallId`; `interaction.request` (approval/question) waits for the person until `interaction.resolved`.
///   Output: turn-scoped `usage.record` `usage.output`; context = its input + cache counts. Model: `llm.request.model` (compaction
///   requests skipped). Speed: a `step.end`'s output over `llmFirstTokenLatencyMs` + `llmStreamDurationMs`. `state.json`: `cwd`
///   (older `workDir`), the title only when `titleKind` is `generated`/`custom` (never for sessions imported from kimi-cli), and a
///   subagent's `agents.<id>.labels.profileName`.
/// - kimi-cli: `<KIMI_SHARE_DIR | %USERPROFILE%\.kimi>\sessions\<md5(work dir)>\<session>\wire.jsonl` (+ `subagents\<id>\` with
///   `meta.json`). Lines `{"timestamp" (s), "message": {"type", "payload"}}`. Output from `StatusUpdate.token_usage.output` once per
///   `message_id` within a step; context from `context_tokens`/`max_context_tokens`; project from `kimi.json`; model from a subagent's
///   `meta.json`, else `config.toml` `default_model` → `[models.<alias>] model`. No title, no speed. Sessions written before
///   `.migrated-to-kimi-code` are left to the Kimi Code reader.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Kimi = new(KimiFiles, path => path.Replace('\\', '/').EndsWith("/wire.jsonl", StringComparison.Ordinal),
        path => KimiLog.IsKimiCode(path) ? new KimiCodeLogReader(path) : (ITokenLogReader)new KimiCLILogReader(path));

    static List<string> KimiFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var main = new List<FileSystemInfo>();
        var subagents = new List<FileSystemInfo>();
        foreach (var root in roots)
        {
            var marker = Path.Combine(Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(root)) ?? root, ".migrated-to-kimi-code");
            DateTime? migrated = File.Exists(marker) ? File.GetLastWriteTimeUtc(marker) : null;
            FileInfo? Legacy(string wire)
            {
                var info = new FileInfo(wire);
                return info.Exists && (migrated is not { } cutoff || info.LastWriteTimeUtc > cutoff) ? info : null;
            }
            foreach (var workspace in TokenDiscovery.Children(root).OfType<DirectoryInfo>())
                foreach (var session in TokenDiscovery.Children(workspace.FullName).OfType<DirectoryInfo>())
                {
                    var agents = TokenDiscovery.Children(Path.Combine(session.FullName, "agents"));
                    foreach (var agent in agents.OfType<DirectoryInfo>())
                    {
                        var wire = new FileInfo(Path.Combine(agent.FullName, "wire.jsonl"));
                        if (!wire.Exists) continue;
                        (agent.Name == KimiLog.MainAgent ? main : subagents).Add(wire);
                    }
                    if (agents.Count > 0) continue;
                    if (Legacy(Path.Combine(session.FullName, "wire.jsonl")) is { } legacy) main.Add(legacy);
                    foreach (var agent in TokenDiscovery.Children(Path.Combine(session.FullName, "subagents")).OfType<DirectoryInfo>())
                        if (Legacy(Path.Combine(agent.FullName, "wire.jsonl")) is { } child) subagents.Add(child);
                }
        }
        // Subagents come in bursts; they get their own cap so main sessions stay visible.
        return [.. discovery.Recent(main), .. discovery.Recent(subagents, discovery.Now.UtcDateTime.AddHours(-1))];
    }
}

public static class KimiLog
{
    public const string MainAgent = "main";

    /// `…\agents\<agent>\wire.jsonl` is Kimi Code; kimi-cli keeps `wire.jsonl` in the session folder or `subagents\<id>\`.
    public static bool IsKimiCode(string path) =>
        Path.GetFileName(Path.GetDirectoryName(Path.GetDirectoryName(path))) == "agents";

    /// The Kimi desktop app's embedded runtime (Kimi Work) keeps its Kimi Code home under its app data.
    public static string? ClientName(string path) =>
        path.Replace('\\', '/').Contains("/kimi-desktop/daimon-share/", StringComparison.Ordinal) ? "Kimi Work" : null;

    internal static readonly byte[] TypeKey = "{\"type\":\""u8.ToArray();
    internal static readonly byte[] EventKey = "\"event\":{\"type\":\""u8.ToArray();
    internal static readonly byte[] ToolCallKey = "\"toolCallId\":\""u8.ToArray();
    internal static readonly byte[] MessageTypeKey = "\"message\":{\"type\":\""u8.ToArray();
    static readonly byte[] TimeKey = "\"time\":"u8.ToArray();
    static readonly byte[] TimestampKey = "{\"timestamp\":"u8.ToArray();

    /// The string after `key` within the line's first `limit` bytes, so a line with long text is not parsed for one field.
    /// Null when absent or escaped (type names and ids hold neither quotes nor backslashes).
    public static string? Sniff(byte[] data, byte[] key, int limit, bool leading = false)
    {
        var window = data.AsSpan(0, Math.Min(limit, data.Length));
        var at = window.IndexOf(key);
        if (at < 0 || (leading && at != 0)) return null;
        var rest = window[(at + key.Length)..];
        var end = rest.IndexOf((byte)'"');
        if (end <= 0 || rest[..end].Contains((byte)'\\')) return null;
        return Encoding.UTF8.GetString(rest[..end]);
    }

    /// The `"time":<ms>}` that ends every Kimi Code record (the serializer writes it last).
    public static DateTimeOffset? TrailingTime(byte[] data)
    {
        var end = data.Length;
        while (end > 0 && data[end - 1] is 9 or 10 or 13 or 32) end--;
        if (end == 0 || data[end - 1] != (byte)'}') return null;
        var digitsEnd = end - 1;
        var start = digitsEnd;
        while (start > 0 && data[start - 1] is >= 48 and <= 57) start--;
        if (start == digitsEnd || start < TimeKey.Length || !data.AsSpan(start - TimeKey.Length, TimeKey.Length).SequenceEqual(TimeKey)
            || !double.TryParse(data.AsSpan(start, digitsEnd - start), NumberStyles.None, CultureInfo.InvariantCulture, out var ms)) return null;
        return ms > 0 && ms < 253_370_764_800_000 ? DateTimeOffset.UnixEpoch.AddTicks((long)(ms * TimeSpan.TicksPerMillisecond)) : null;
    }

    /// The `{"timestamp":<seconds>` that opens every kimi-cli record.
    public static DateTimeOffset? LeadingSeconds(byte[] data)
    {
        if (!data.AsSpan().StartsWith(TimestampKey)) return null;
        var rest = data.AsSpan(TimestampKey.Length, Math.Min(32, data.Length - TimestampKey.Length));
        var length = 0;
        while (length < rest.Length && (rest[length] is >= 48 and <= 57 || rest[length] == (byte)'.')) length++;
        return double.TryParse(rest[..length], NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var seconds)
            ? Seconds(seconds) : null;
    }

    /// Epoch seconds as TokenLogParser.date reads a number.
    public static DateTimeOffset? Seconds(double? seconds) =>
        seconds is { } value && value > 0 && value < 253_370_764_800 ? DateTimeOffset.UnixEpoch.AddTicks((long)(value * TimeSpan.TicksPerSecond)) : null;

    /// The model id sent to the provider: a `kimi-code/` prefix dropped, symbolic config references (`__kimi_env_model__`) refused.
    public static string? ModelName(JsonElement? value) => ModelName(LogFields.Text(value));

    public static string? ModelName(string? value)
    {
        if (value?.Trim(' ', '\t') is not { Length: > 0 } name || new StringInfo(name).LengthInTextElements > 128) return null;
        if (name.StartsWith("kimi-code/", StringComparison.Ordinal)) name = name["kimi-code/".Length..];
        return name.Length == 0 || (name.Length >= 4 && name.StartsWith("__", StringComparison.Ordinal) && name.EndsWith("__", StringComparison.Ordinal))
            ? null : name;
    }

    /// A Kimi Code session title the client generated or the person set, as its own loader reads `state.json`. Imported
    /// kimi-cli sessions map its prompt fallbacks to `generated`, so they have none.
    public static string? Title(JsonElement state)
    {
        if (state.Field("custom")?.Field("imported_from_kimi_cli")?.Bool == true) return null;
        if (state.Field("title") is { ValueKind: JsonValueKind.String } title)
        {
            if (state.Field("isCustomTitle")?.Bool == true) return SessionTitle.Clean(title);
            if (state.Field("titleKind")?.Text is { } kind) return kind is "generated" or "custom" ? SessionTitle.Clean(title) : null;
            return null;
        }
        return SessionTitle.Clean(state.Field("customTitle"));
    }

    /// A non-negative duration in milliseconds.
    public static double? Duration(JsonElement? value) => value?.Number is { } ms && ms >= 0 ? ms : null;

    /// Creation time, size and write time of a small side file; null when it is missing.
    public static (long, long, long)? Stamp(string path)
    {
        var info = new FileInfo(path);
        return info.Exists ? (info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks) : null;
    }

    /// A side file of at most `limit` bytes.
    public static byte[]? Bytes(string path, long limit = 4_194_304)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > limit) return null;
            var data = new byte[stream.Length];
            stream.ReadExactly(data);
            return data;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    /// The same as a JSON object.
    public static JsonElement? Object(string path, long limit = 4_194_304) =>
        Bytes(path, limit) is { } data && Json.Parse(data) is { ValueKind: JsonValueKind.Object } value ? value : null;

    /// kimi-cli's configured model: `default_model` names a `[models.<alias>]` table whose `model` is the provider's id.
    public static string? ConfiguredModel(string toml)
    {
        static string Value(string text)
        {
            text = text.Trim(' ', '\t');
            if (text.Length > 0 && text[0] is '"' or '\'')
            {
                var quote = text[0];
                text = text[1..];
                var close = text.IndexOf(quote);
                if (close >= 0) text = text[..close];
            }
            else if (text.IndexOf('#') is var comment and >= 0) text = text[..comment].Trim(' ', '\t');
            return text;
        }
        string? alias = null;
        string? section = null;
        var models = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in toml.Split('\n', '\r'))
        {
            var line = raw.Trim(' ', '\t');
            if (line.StartsWith('['))
            {
                var name = line[1..];
                if (name.IndexOf(']') is var close and >= 0) name = name[..close];
                section = name.StartsWith("models.", StringComparison.Ordinal) ? Value(name["models.".Length..]) : "";
                continue;
            }
            var equals = line.IndexOf('=');
            if (equals < 0) continue;
            var key = line[..equals].Trim(' ', '\t');
            if (section is null && key == "default_model") alias = Value(line[(equals + 1)..]);
            if (section is { Length: > 0 } table && key == "model") models[table] = Value(line[(equals + 1)..]);
        }
        return alias is not null && models.TryGetValue(alias, out var model) ? ModelName(model) : null;
    }

    /// The same from the JSON config kimi-cli used before `config.toml`.
    public static string? ConfiguredModel(JsonElement json) =>
        json.Field("default_model")?.Text is { } alias ? ModelName(json.Field("models")?.Field(alias)?.Field("model")) : null;

    /// kimi-cli names a work directory's session folder by the md5 of its path (`<kaos>_<md5>` off the local machine).
    public static string WorkDirFolder(string path, string? kaos)
    {
        var hash = Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(path)));
        return kaos is { Length: > 0 } and not "local" ? $"{kaos}_{hash}" : hash;
    }
}

/// One Kimi Code agent journal: the main agent (a session row) or a subagent grouped under it.
public sealed class KimiCodeLogReader : ITokenLogReader
{
    static readonly HashSet<string> InputTools = new(StringComparer.Ordinal) { "AskUserQuestion" };
    /// Record types read whole; every other line is read only for its trailing time (and type when it has no free text).
    static readonly HashSet<string> ParsedTypes = new(StringComparer.Ordinal)
    {
        "turn.ended", "llm.request", "usage.record", "interaction.request", "interaction.resolved", "profile.bind", "config.update",
    };

    readonly LogLineTail tail;
    readonly string statePath;
    (long, long, long)? stateStamp;
    readonly string sessionID;
    readonly string agentID;
    readonly string? clientName;
    LogTurnState turn = new(InputTools);
    string? cwd;
    /// The cwd the agent's profile disclosed, used when `state.json` has none.
    string? boundCwd;
    string? title;
    string? role;
    string? model;
    string? effort;
    TokenContextUsage? context;
    TokenSpeedMeasurement? measurement;
    /// The client's own duration of the last completed turn.
    double? turnSeconds;

    public KimiCodeLogReader(string path)
    {
        tail = new LogLineTail(path);
        var agent = Path.GetDirectoryName(path)!;
        agentID = Path.GetFileName(agent);
        var session = Path.GetDirectoryName(Path.GetDirectoryName(agent))!;
        sessionID = Path.GetFileName(session);
        statePath = Path.Combine(session, "state.json");
        clientName = KimiLog.ClientName(path);
    }

    bool IsSubagent => agentID != KimiLog.MainAgent;

    public bool IsRecent(DateTimeOffset now) => turn.IsRecent(now);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        if (turn.Reading(TokenSource.Kimi, id, model, cwd ?? boundCwd, now) is not { } reading) return [];
        reading = reading with
        {
            ClientName = clientName, SessionID = sessionID, Effort = effort, Context = context, SpeedMeasurement = measurement,
            LastTurnDurationSeconds = reading.LastOutputTokens is not null ? turnSeconds : null,
        };
        return [IsSubagent
            ? reading with { IsSubagent = true, ParentSessionID = sessionID, AgentID = agentID, AgentRole = role }
            : reading with { Title = title }];
    }

    public void Read(int tailLimit, DateTimeOffset now)
    {
        turn.Clamp(now.AddSeconds(5));
        tail.Read(tailLimit, () =>
        {
            turn = new LogTurnState(InputTools);
            context = null;
            measurement = null;
            turnSeconds = null;
        }, Consume);
        ReadState();
    }

    /// `state.json` is rewritten whole on every metadata change (title, agents); read again when its file, size or time changed.
    void ReadState()
    {
        if (KimiLog.Stamp(statePath) is not { } current || current == stateStamp) return;
        stateStamp = current;
        if (KimiLog.Object(statePath) is not { } state) return;
        cwd = LogFields.Text(state.Field("cwd")) ?? LogFields.Text(state.Field("workDir")) ?? cwd;
        title = KimiLog.Title(state);
        role = TokenLogParser.Label(state.Field("agents")?.Field(agentID)?.Field("labels")?.Field("profileName")) ?? role;
    }

    void Consume(byte[] data)
    {
        var type = KimiLog.Sniff(data, KimiLog.TypeKey, 64, leading: true);
        var @event = type == "context.append_loop_event" ? KimiLog.Sniff(data, KimiLog.EventKey, 256) : null;
        var toolCall = @event == "tool.result" ? KimiLog.Sniff(data, KimiLog.ToolCallKey, 512) : null;
        var at = KimiLog.TrailingTime(data);
        JsonElement? record = null;
        var light = type is "turn.prompt" or "turn.steer" || @event is "content.part" or "step.begin"
            || (@event == "tool.result" && toolCall is not null)
            || (type is not null && type != "context.append_loop_event" && !ParsedTypes.Contains(type));
        if (!light || at is null)
        {
            if (Json.Parse(data) is not { ValueKind: JsonValueKind.Object } parsed || parsed.Field("type")?.Text is not { } name) return;
            record = parsed;
            type = name;
            at = LogFields.Milliseconds(parsed.Field("time")) ?? at;
            @event = parsed.Field("event")?.Field("type")?.Text;
            toolCall = LogFields.Text(parsed.Field("event")?.Field("toolCallId"));
        }
        turn.Logged(at);
        var loop = record?.Field("event");
        switch (type)
        {
            case "turn.prompt": turn.Begin(at); break;
            case "turn.steer": turn.Resume(at); break;
            case "turn.ended":
                // Nothing read before it: the turn began before the tail.
                if (!turn.TurnOpen && turn.LastActivity is null) turn.Resume(at);
                if (!turn.TurnOpen) break;
                if (record?.Field("reason")?.Text == "completed")
                {
                    turn.Close(TokenActivityState.Complete, at, model);
                    turnSeconds = LogFields.Count(record?.Field("durationMs")) is { } duration ? duration / 1_000.0 : null;
                }
                else turn.Close(TokenActivityState.Interrupted, at, model);
                break;
            case "context.append_loop_event":
                switch (@event)
                {
                    case "step.begin" or "content.part":
                        turn.Resume(at);
                        turn.SetState(turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, at);
                        break;
                    case "tool.call":
                        if (LogFields.Text(loop?.Field("toolCallId")) is not { } id) break;
                        turn.Resume(at);
                        turn.StartTool(id, TokenLogParser.Label(loop?.Field("name")), at);
                        break;
                    case "tool.result":
                        if (toolCall is not null) turn.FinishTool(toolCall, at);
                        break;
                    case "step.end":
                        turn.Touch(at);
                        Measure(loop, at);
                        break;
                }
                break;
            case "llm.request":
                // A compaction request (also run by /compact between turns) neither opens a turn nor names the session's model.
                if (record?.Field("kind")?.Text == "compaction") break;
                turn.Resume(at);
                turn.SetState(turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, at);
                model = KimiLog.ModelName(record?.Field("model")) ?? model;
                if (TokenLogParser.Label(record?.Field("thinkingEffort")) is { } level) effort = level == "off" ? null : level;
                break;
            case "usage.record":
                // `session`-scoped records are bookkeeping outside a turn (compaction, titles); Kimi Code's own totals skip them.
                if (record?.Field("usageScope")?.Text != "turn" || record?.Field("usage") is not { ValueKind: JsonValueKind.Object } usage) break;
                if (turn.LastActivity is null) turn.Resume(at);
                turn.AddOutput(LogFields.Count(usage.Field("output")) ?? 0, at);
                var used = new[] { "inputOther", "inputCacheRead", "inputCacheCreation" }
                    .Aggregate(0, (sum, key) => LogFields.Add(sum, LogFields.Count(usage.Field(key)) ?? 0));
                if (used > 0 && at is { } recorded) context = new TokenContextUsage(used, null, recorded, null);
                break;
            case "interaction.request":
                if (LogFields.Text(record?.Field("id")) is not { } request || record?.Field("kind")?.Text is not ("approval" or "question")) break;
                turn.Resume(at);
                turn.StartRequest(request, at);
                break;
            case "interaction.resolved":
                if (LogFields.Text(record?.Field("id")) is { } resolved) turn.FinishRequest(resolved);
                break;
            case "profile.bind" or "config.update":
                boundCwd = LogFields.Text(record?.Field("environmentDisclosure")?.Field("cwd")) ?? boundCwd;
                if (IsSubagent) role = TokenLogParser.Label(record?.Field("profileName")) ?? role;
                break;
        }
    }

    /// The client's own timing of one model call: output over first-token latency plus streaming time.
    void Measure(JsonElement? step, DateTimeOffset? at)
    {
        if (step is null || at is not { } finished || step.Value.Field("finishReason")?.Text is "interrupted" or "error" or "cancelled"
            || LogFields.Count(step.Value.Field("usage")?.Field("output")) is not { } output || output <= 0
            || KimiLog.Duration(step.Value.Field("llmFirstTokenLatencyMs")) is not { } firstToken
            || KimiLog.Duration(step.Value.Field("llmStreamDurationMs")) is not { } streaming || firstToken + streaming <= 0) return;
        measurement = new TokenSpeedMeasurement
        {
            Model = model, At = finished, OutputTokens = output, RequestDurationMs = firstToken + streaming, TtftMs = firstToken,
        };
    }
}

/// One archived kimi-cli journal: a session or one of its subagents.
public sealed class KimiCLILogReader : ITokenLogReader
{
    readonly LogLineTail tail;
    readonly string sessionID;
    readonly string? agentID;
    readonly string group;
    readonly string shareDir;
    readonly string? metaPath;
    LogTurnState turn = new();
    string? cwd;
    string? role;
    string? agentModel;
    string? configModel;
    TokenContextUsage? context;
    /// `StatusUpdate`s already counted in the current step, by `message_id`: a step makes one model call, and some
    /// OpenAI-compatible gateways reuse one response id for every call, so ids are only compared within a step.
    readonly HashSet<string> counted = new(StringComparer.Ordinal);
    /// Open `QuestionRequest`s by tool call; its tool result answers it.
    readonly Dictionary<string, string> questions = new(StringComparer.Ordinal);
    (long, long, long)? workDirsStamp;
    (long, long, long)? configStamp;
    (long, long, long)? metaStamp;

    public KimiCLILogReader(string path)
    {
        tail = new LogLineTail(path);
        var folder = Path.GetDirectoryName(path)!;
        string session;
        if (Path.GetFileName(Path.GetDirectoryName(folder)) == "subagents")
        {
            session = Path.GetDirectoryName(Path.GetDirectoryName(folder))!;
            agentID = Path.GetFileName(folder);
            metaPath = Path.Combine(folder, "meta.json");
        }
        else session = folder;
        sessionID = Path.GetFileName(session);
        var groupFolder = Path.GetDirectoryName(session)!;
        group = Path.GetFileName(groupFolder);
        shareDir = Path.GetDirectoryName(Path.GetDirectoryName(groupFolder)!)!;
    }

    string? Model => agentModel ?? configModel;

    public bool IsRecent(DateTimeOffset now) => turn.IsRecent(now);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        if (turn.Reading(TokenSource.Kimi, id, Model, cwd, now) is not { } reading) return [];
        reading = reading with { ClientName = "Kimi CLI", SessionID = sessionID, Context = context };
        return [agentID is null ? reading : reading with { IsSubagent = true, ParentSessionID = sessionID, AgentID = agentID, AgentRole = role }];
    }

    public void Read(int tailLimit, DateTimeOffset now)
    {
        turn.Clamp(now.AddSeconds(5));
        tail.Read(tailLimit, () =>
        {
            turn = new LogTurnState();
            context = null;
            counted.Clear();
            questions.Clear();
        }, Consume);
        if (cwd is null) ReadWorkDirs();
        ReadConfig();
        ReadMeta();
    }

    /// `kimi.json` lists every work directory; the one whose md5 names this session's folder is the project.
    void ReadWorkDirs()
    {
        var path = Path.Combine(shareDir, "kimi.json");
        if (KimiLog.Stamp(path) is not { } current || current == workDirsStamp) return;
        workDirsStamp = current;
        foreach (var entry in LogFields.Objects(KimiLog.Object(path)?.Field("work_dirs")))
        {
            if (LogFields.Text(entry.Field("path")) is not { } workDir || KimiLog.WorkDirFolder(workDir, entry.Field("kaos")?.Text) != group) continue;
            cwd = workDir;
            return;
        }
    }

    void ReadConfig()
    {
        var toml = Path.Combine(shareDir, "config.toml");
        var path = File.Exists(toml) ? toml : Path.Combine(shareDir, "config.json");
        if (KimiLog.Stamp(path) is not { } current || current == configStamp) return;
        configStamp = current;
        if (path == toml)
        {
            if (KimiLog.Bytes(path, 1_048_576) is { } data) configModel = KimiLog.ConfiguredModel(Encoding.UTF8.GetString(Json.StripBom(data)));
        }
        else configModel = KimiLog.Object(path, 1_048_576) is { } json ? KimiLog.ConfiguredModel(json) : null;
    }

    /// A subagent's `meta.json`: its type and the model it ran on.
    void ReadMeta()
    {
        if (metaPath is null || KimiLog.Stamp(metaPath) is not { } current || current == metaStamp) return;
        metaStamp = current;
        if (KimiLog.Object(metaPath, 1_048_576) is not { } meta) return;
        role = TokenLogParser.Label(meta.Field("subagent_type")) ?? role;
        agentModel = KimiLog.ModelName(meta.Field("launch_spec")?.Field("effective_model")) ?? agentModel;
    }

    void Consume(byte[] data)
    {
        // Streamed content is the bulk of the journal; it only shows the turn is still writing.
        var sniffed = KimiLog.Sniff(data, KimiLog.MessageTypeKey, 96);
        if (sniffed is "ContentPart" or "ToolCallPart" && KimiLog.LeadingSeconds(data) is { } streamed)
        {
            turn.Logged(streamed);
            turn.Resume(streamed);
            turn.SetState(turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, streamed);
            return;
        }
        if (Json.Parse(data) is not { ValueKind: JsonValueKind.Object } record || record.Field("message") is not { ValueKind: JsonValueKind.Object } message
            || message.Field("type")?.Text is not { } type) return;
        var at = KimiLog.Seconds(record.Field("timestamp")?.Number);
        turn.Logged(at);
        var payload = message.Field("payload");
        switch (type)
        {
            case "TurnBegin":
                counted.Clear();
                turn.Begin(at);
                break;
            case "SteerInput": turn.Resume(at); break;
            case "StepBegin" or "ContentPart" or "ToolCallPart":
                if (type == "StepBegin") counted.Clear();
                turn.Resume(at);
                turn.SetState(turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, at);
                break;
            case "ToolCall":
                if (LogFields.Text(payload?.Field("id")) is not { } call) break;
                turn.Resume(at);
                turn.StartTool(call, TokenLogParser.Label(payload?.Field("function")?.Field("name")), at);
                break;
            case "ToolResult":
                if (LogFields.Text(payload?.Field("tool_call_id")) is not { } result) break;
                turn.FinishTool(result, at);
                if (questions.Remove(result, out var question)) turn.FinishRequest(question);
                break;
            case "ApprovalRequest" or "QuestionRequest":
                if (LogFields.Text(payload?.Field("id")) is not { } request) break;
                turn.Resume(at);
                turn.StartRequest(request, at);
                if (type == "QuestionRequest" && LogFields.Text(payload?.Field("tool_call_id")) is { } asked) questions[asked] = request;
                break;
            case "ApprovalResponse" or "ApprovalRequestResolved":
                if (LogFields.Text(payload?.Field("request_id")) is { } answered) turn.FinishRequest(answered);
                break;
            case "StatusUpdate":
                if (LogFields.Count(payload?.Field("context_tokens")) is { } used and > 0 && at is { } recorded)
                    context = new TokenContextUsage(used, LogFields.Count(payload?.Field("max_context_tokens")) is { } window and > 0 ? window : null, recorded, null);
                if (payload?.Field("token_usage") is not { ValueKind: JsonValueKind.Object } usage || LogFields.Count(usage.Field("output")) is not { } output) break;
                if (LogFields.Text(payload?.Field("message_id")) is { } messageID)
                {
                    if (!counted.Add(messageID)) break;
                    if (counted.Count > 1_024) counted.Clear();
                }
                if (turn.LastActivity is null) turn.Resume(at);
                turn.AddOutput(output, at);
                break;
            case "StepInterrupted": turn.Close(TokenActivityState.Interrupted, at, Model); break;
            case "TurnEnd": turn.Close(TokenActivityState.Complete, at, Model); break;
        }
    }
}
