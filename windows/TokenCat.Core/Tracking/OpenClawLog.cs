using System.Text;
using System.Text.Json;

namespace TokenCat;

/// OpenClawLog.swift: OpenClaw (earlier Clawdbot and Moltbot) keeps every agent under `<state dir>\agents\<agentId>\`, in
/// one of two generations (openclaw/openclaw `src/state/openclaw-agent-schema.sql`, `src/agents/sessions/session-manager.ts`):
/// - SQLite (v2026.8.1 on): `agent\openclaw-agent.sqlite`, one reader per database (`OpenClawDatabaseLog`). Sessions are
///   `session_windows` rows (one per transcript generation of a `session_nodes` key); `transcript_events` holds each
///   session's Pi-format entries by `seq`. Since agent schema 23 (v2026.9.6) an entry of 1 KiB or more is usually stored as
///   a zstd frame (`event_zstd`) with uncompressed `navigation_json` facts; .NET and macOS have no zstd decoder, so such a
///   row is read from those facts alone: kind, role, times, provider and model, stop reason, tool call ids and names — not
///   its usage.
/// - JSONL (before v2026.8.1): `sessions\<sessionId>.jsonl` with a `sessions.json` index (`OpenClawLogReader`).
/// Both carry the same entries: a `session` header (`id`, `cwd`), `message` entries `{timestamp, message: {role,
/// timestamp, provider, model, api, usage{input, output, cacheRead, cacheWrite}, stopReason, endTurn, content[toolCall
/// {id, name}]}}`, `toolResult` messages with `toolCallId`, and `model_change` / `custom` `model-snapshot` records.
/// - Turn: the person's message opens it; an assistant reply with tool calls waits on them (`ask_user` waits for the
///   person); `stopReason` `stop` (unless `endTurn: false`) or `length` completes it, `aborted` or `error` interrupts it.
///   Assistant rows OpenClaw writes as transcript bookkeeping (`api: openclaw-transcript`, provider `openclaw` with model
///   `delivery-mirror` / `gateway-injected`, a delivery-mirror marker) are not model output and are skipped
///   (`src/shared/transcript-only-openclaw-assistant.ts`).
/// - Tokens: each readable reply's `usage.output` at its log time. A turn holding a reply whose usage is unreadable (a
///   compressed row) or that mirrors a Codex app-server turn (`idempotencyKey` `codex-app-server:…`, which carries only
///   the last response's usage) has no whole count until the session entry's `outputTokens` — the client's own total for
///   the run it wrote after the run ended — settles it; the rest of that total is logged at the entry's write time.
/// - Session entry (`session_nodes.entry_json` / `sessions.json`): `label` (a rename) or `displayName` (a generated or
///   channel title) as the title, `spawnedBy` / `spawnedBySessionId` for subagents (named by their spawn `label`), `model`,
///   and a fresh `totalTokens` with its `contextTokens` window as context. No request duration is recorded, so no speed.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat OpenClaw = new(OpenClawFiles, OpenClawLog.IsLog,
        path => Path.GetFileName(path) == OpenClawLog.DatabaseName ? new OpenClawDatabaseLog(path) : new OpenClawLogReader(path));

    static List<string> OpenClawFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var databases = new List<FileSystemInfo>();
        var transcripts = new List<FileSystemInfo>();
        foreach (var root in roots)
            foreach (var agent in TokenDiscovery.Children(root))
            {
                if (agent is not DirectoryInfo) continue;
                var database = new FileInfo(Path.Combine(agent.FullName, "agent", OpenClawLog.DatabaseName));
                if (database.Exists) databases.Add(database);
                transcripts.AddRange(TokenDiscovery.Children(Path.Combine(agent.FullName, "sessions"))
                    .Where(entry => entry is FileInfo && entry.Name.EndsWith(".jsonl", StringComparison.Ordinal)));
            }
        return [.. discovery.Recent(databases), .. discovery.Recent(transcripts)];
    }
}

public static class OpenClawLog
{
    public const string DatabaseName = "openclaw-agent.sqlite";

    /// `<agents>\<agentId>\agent\openclaw-agent.sqlite` or `<agents>\<agentId>\sessions\<session>.jsonl`. Archives
    /// (`.jsonl.reset.<time>`, `cold\*.jsonl.zst`), the doctor's import archive and Codex homes are never logs.
    public static bool IsLog(string path)
    {
        var parts = path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 4 || parts[^4] != "agents") return false;
        if (parts[^1] == DatabaseName) return parts[^2] == "agent";
        return path.EndsWith(".jsonl", StringComparison.Ordinal) && parts[^2] == "sessions";
    }

    /// OpenClaw's tool names (`docs/tools`); anything else falls back to the shared table.
    public static ToolCategory Category(string name) => name switch
    {
        "exec" or "process" or "bash" or "code_execution" or "terminal" => ToolCategory.Command,
        "read" or "write" or "edit" or "apply_patch" => ToolCategory.File,
        "web_search" or "web_fetch" or "x_search" or "browser" => ToolCategory.Web,
        "sessions_spawn" or "sessions_send" or "subagents" or "agents_list" or "agents_wait" => ToolCategory.Agent,
        "ask_user" => ToolCategory.Question,
        _ => TokenLogParser.Category(name),
    };

    internal static string? Label(string? value) => value is null ? null : TokenLogParser.Label(JsonSerializer.SerializeToElement(value));

    /// A non-negative whole count that fits an Int32 (`LogFields.count` of an SQL integer).
    internal static int? Count(long? value) => value is >= 0 and <= int.MaxValue ? (int)value : null;
}

/// One transcript entry reduced to what TokenCat keeps: kind, role, times, model, stop reason, usage counts, tool call ids
/// and names. Built from a JSONL line or from one `transcript_events` row's SQL projection; never text.
public sealed record OpenClawEvent
{
    public string? Type { get; set; }
    /// The entry's `timestamp`, else the row's `created_at`.
    public DateTimeOffset? At { get; set; }
    public string? Role { get; set; }
    /// `message.timestamp`: when an assistant reply's request started.
    public DateTimeOffset? StartedAt { get; set; }
    public string? Provider { get; set; }
    public string? Model { get; set; }
    public string? Api { get; set; }
    public string? MirrorKind { get; set; }
    public string? StopReason { get; set; }
    public bool? EndTurn { get; set; }
    /// Null when the reply's usage could not be read.
    public int? Output { get; set; }
    public int Context { get; set; }
    public List<(string Id, string? Name)> ToolCalls { get; } = [];
    public string? ToolCallID { get; set; }
    public bool CodexMirror { get; set; }
    public string? SessionID { get; set; }
    public string? Cwd { get; set; }
    /// `model_change.modelId` or a `model-snapshot`'s `data.modelId`.
    public string? ModelChange { get; set; }

    static readonly HashSet<string> CallTypes = ["toolCall", "toolUse", "functionCall"];
    static readonly HashSet<string> MirrorKinds = ["channel-final", "channel-final-suppressed", "message-tool-source-reply", "cron-direct-delivery-context"];

    public static OpenClawEvent FromRecord(JsonElement record)
    {
        var result = new OpenClawEvent { Type = record.Field("type")?.Text, At = LogFields.Date(record.Field("timestamp")) };
        switch (result.Type)
        {
            case "session":
                result.SessionID = LogFields.Text(record.Field("id"));
                result.Cwd = record.Field("cwd")?.Text is { Length: > 0 and <= 4_096 } cwd ? cwd : null;
                break;
            case "model_change":
                result.ModelChange = LogFields.Text(record.Field("modelId"));
                break;
            case "custom" when record.Field("customType")?.Text == "model-snapshot":
                result.ModelChange = LogFields.Text(record.Field("data")?.Field("modelId"));
                break;
            case "message" when record.Field("message") is { ValueKind: JsonValueKind.Object } message:
                result.Role = message.Field("role")?.Text;
                result.StartedAt = LogFields.Milliseconds(message.Field("timestamp"));
                result.At ??= result.StartedAt;
                result.ToolCallID = LogFields.Text(message.Field("toolCallId"));
                if (result.Role != "assistant") break;
                result.Provider = LogFields.Text(message.Field("provider"));
                result.Model = LogFields.Text(message.Field("model"));
                result.Api = LogFields.Text(message.Field("api"));
                result.MirrorKind = message.Field("openclawDeliveryMirror") is { ValueKind: JsonValueKind.Object } mirror ? LogFields.Text(mirror.Field("kind")) : null;
                result.StopReason = message.Field("stopReason")?.Text;
                result.EndTurn = message.Field("endTurn")?.Bool;
                result.CodexMirror = message.Field("idempotencyKey")?.Text?.StartsWith("codex-app-server:", StringComparison.Ordinal) == true;
                var usage = message.Field("usage");
                result.Output = LogFields.Count(usage?.Field("output")) ?? 0;
                result.Context = new[] { "input", "cacheRead", "cacheWrite" }
                    .Aggregate(0, (sum, key) => LogFields.Add(sum, LogFields.Count(usage?.Field(key)) ?? 0));
                foreach (var block in LogFields.Objects(message.Field("content")))
                    if (CallTypes.Contains(block.Field("type")?.Text ?? "") && LogFields.Text(block.Field("id")) is { } id)
                        result.ToolCalls.Add((id, TokenLogParser.Label(block.Field("name"))));
                break;
        }
        return result;
    }

    /// A reply OpenClaw wrote itself as transcript bookkeeping, not model output.
    public bool IsArtifact =>
        Api == "openclaw-transcript"
        || (Provider == "openclaw" && Model is "delivery-mirror" or "gateway-injected")
        || MirrorKinds.Contains(MirrorKind ?? "");
}

/// What a session entry (`session_nodes.entry_json`, `sessions.json`) adds: client titles, subagent identity, the run's
/// output total and the context snapshot. Only these fields are read.
public sealed record OpenClawSessionFacts
{
    public DateTimeOffset? UpdatedAt { get; init; }
    public string? Title { get; init; }
    public bool IsSubagent { get; init; }
    public string? ParentSessionID { get; init; }
    public string? Role { get; init; }
    public int? OutputTokens { get; init; }
    public int? ContextUsed { get; init; }
    public int? ContextWindow { get; init; }
    public string? Model { get; init; }
    public string? Workspace { get; init; }

    static readonly HashSet<string> TrustedWindows = ["runtime", "runtime-configured", "resolved-v1"];

    /// `label` (a rename, or a subagent's spawn label) wins over `displayName`. `totalTokens` counts as context only while
    /// `totalTokensFresh`; `contextTokens` is the window only when OpenClaw took it from the runtime or its versioned
    /// resolution (`resolved` is its own legacy guess).
    public static OpenClawSessionFacts Make(string? key, string? label, string? displayName, string? spawnedBy, string? parentSessionID,
        DateTimeOffset? updatedAt, int? outputTokens, int? totalTokens, bool fresh, int? contextTokens, string? contextSource,
        string? model, string? workspace)
    {
        var subagent = !string.IsNullOrEmpty(spawnedBy) || key?.Contains(":subagent:", StringComparison.Ordinal) == true;
        return new OpenClawSessionFacts
        {
            UpdatedAt = updatedAt,
            Title = SessionTitle.Clean(label) ?? SessionTitle.Clean(displayName),
            IsSubagent = subagent,
            ParentSessionID = subagent ? parentSessionID : null,
            Role = subagent ? OpenClawLog.Label(label) : null,
            OutputTokens = outputTokens,
            ContextUsed = fresh ? totalTokens : null,
            ContextWindow = TrustedWindows.Contains(contextSource ?? "") ? contextTokens : null,
            Model = model is { Length: > 0 and <= 128 } ? model : null,
            Workspace = workspace is { Length: > 0 and <= 4_096 } ? workspace : null,
        };
    }
}

/// One session's turn state, fed the same events from either generation.
public sealed class OpenClawTurn
{
    public LogTurnState Turn { get; } = new(new HashSet<string> { "ask_user" });
    string? sessionID;
    string? cwd;
    string? model;
    string? modelChange;
    TokenContextUsage? context;
    bool sawContent;
    /// Readable output of the open turn, and whether one of its replies was not readable.
    int turnKnown;
    bool turnUnknown;
    /// The newest completed turn; `Settled` is the entry's total for a turn whose output was not whole.
    (DateTimeOffset At, bool Unknown, int Known, int? Settled)? completed;

    public bool IsOpen => Turn.TurnOpen;

    /// The header a skipped head would lose: identity only.
    public void Identify(OpenClawEvent record)
    {
        if (record.Type != "session") return;
        sessionID ??= record.SessionID;
        cwd ??= record.Cwd;
    }

    public void Consume(OpenClawEvent record, bool headSkipped)
    {
        Turn.Logged(record.At);
        switch (record.Type)
        {
            case "session":
                sessionID = record.SessionID ?? sessionID;
                cwd = record.Cwd ?? cwd;
                break;
            case "model_change" or "custom":
                modelChange = record.ModelChange ?? modelChange;
                break;
            case "message":
                Message(record, unseenStart: headSkipped && !sawContent);
                break;
        }
    }

    void Message(OpenClawEvent record, bool unseenStart)
    {
        if (record.At is not { } at) return;
        switch (record.Role)
        {
            case "user":
                sawContent = true;
                // A message steering a running turn joins it.
                if (Turn.TurnOpen) Turn.SetState(TokenActivityState.Working, at);
                else Open(at, whole: true);
                break;
            case "assistant":
                if (record.IsArtifact) return;
                sawContent = true;
                if (!Turn.TurnOpen) Open(unseenStart ? null : record.StartedAt ?? at, whole: !unseenStart);
                if (record.Model is { Length: <= 128 } name) model = name;
                if (record.Output is { } output)
                {
                    turnKnown = LogFields.Add(turnKnown, output);
                    Turn.AddOutput(output, at);
                }
                else turnUnknown = true;
                if (record.CodexMirror) turnUnknown = true;
                if (record.Context > 0) context = new TokenContextUsage(record.Context, null, at, null);
                foreach (var call in record.ToolCalls) Turn.StartTool(call.Id, call.Name, at);
                if ((record.StopReason == "stop" && record.EndTurn != false) || record.StopReason == "length")
                {
                    Turn.Close(TokenActivityState.Complete, at, model);
                    completed = (at, turnUnknown, turnKnown, null);
                }
                else if (record.StopReason is "aborted" or "error") Turn.Close(TokenActivityState.Interrupted, at, model);
                else Turn.SetState(Turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, at);
                break;
            case "toolResult":
                sawContent = true;
                if (!Turn.TurnOpen) Open(unseenStart ? null : at, whole: !unseenStart);
                if (record.ToolCallID is { } id) Turn.FinishTool(id, at);
                Turn.SetState(Turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, at);
                break;
        }
    }

    void Open(DateTimeOffset? date, bool whole)
    {
        Turn.Begin(date, whole);
        turnKnown = 0;
        turnUnknown = false;
    }

    /// The entry's `outputTokens`, written once a run ended, settles the newest completed turn when its output was not whole
    /// and nothing happened since. The part not already read is logged at the entry's write time.
    public void Settle(OpenClawSessionFacts? facts)
    {
        if (completed is not { Unknown: true, Settled: null } last || Turn.TurnOpen
            || facts is not { OutputTokens: int total, UpdatedAt: { } written } || written < last.At || total < last.Known) return;
        completed = last with { Settled = total };
        Turn.Logged(written);
        Turn.AddOutput(total - last.Known, written);
    }

    public TokenReading? Reading(string id, OpenClawSessionFacts? facts, string? fallbackModel, DateTimeOffset now)
    {
        if (Turn.Reading(TokenSource.OpenClaw, id, model ?? modelChange ?? facts?.Model ?? fallbackModel, cwd ?? facts?.Workspace, now)
            is not { } reading) return null;
        if (Turn.RunningTool is { } tool) reading = reading with { ToolCategory = tool.Name is { } name ? OpenClawLog.Category(name) : ToolCategory.Other };
        if (Turn.TurnOpen && turnUnknown) reading = reading with { CurrentTurnOutputTokens = null };
        if (completed is { Unknown: true } last)
        {
            var output = last.Settled is > 0 ? last.Settled : null;
            reading = reading with { LastOutputTokens = output, MeasurementAt = output is null ? reading.LastActivity : last.At };
        }
        var usage = context;
        if (facts is { ContextUsed: int used and > 0, UpdatedAt: { } at } && at > (usage?.RecordedAt ?? DateTimeOffset.MinValue))
            usage = new TokenContextUsage(used, null, at, null);
        if (usage is not null) usage = usage with { WindowTokens = facts?.ContextWindow };
        reading = reading with { SessionID = sessionID, Context = usage };
        if (facts is not null)
            reading = facts.IsSubagent
                ? reading with { IsSubagent = true, ParentSessionID = facts.ParentSessionID, AgentID = sessionID, AgentRole = facts.Role }
                : reading with { Title = facts.Title };
        return reading;
    }
}

// JSONL (before v2026.8.1)

/// One `sessions\<sessionId>.jsonl` transcript, appended entry by entry; its `sessions.json` entry adds titles and subagent
/// identity.
public sealed class OpenClawLogReader(string path) : ITokenLogReader
{
    readonly LogLineTail tail = new(path);
    OpenClawTurn state = new();
    bool headerRead;
    OpenClawSessionFacts? facts;

    public void Read(int tailLimit, DateTimeOffset now)
    {
        state.Turn.Clamp(now.AddSeconds(5));
        tail.Read(tailLimit, () =>
        {
            state = new OpenClawTurn();
            headerRead = false;
        }, line =>
        {
            if (Json.Parse(line) is { } record) state.Consume(OpenClawEvent.FromRecord(record), tail.SkippedHead);
        });
        if (tail.SkippedHead && !headerRead)
        {
            headerRead = true;
            if (tail.FirstLine() is { } line && Json.Parse(line) is { } record) state.Identify(OpenClawEvent.FromRecord(record));
        }
        facts = OpenClawSessionIndex.Facts(tail.Path);
        state.Settle(facts);
    }

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        if (state.Reading(id, facts, null, now) is not { } reading) return [];
        reading = reading with { SessionID = reading.SessionID ?? SessionID(tail.Path) };
        if (reading.IsSubagent) reading = reading with { AgentID = reading.SessionID };
        return [reading];
    }

    public bool IsRecent(DateTimeOffset now) => state.Turn.IsRecent(now);

    /// `<sessionId>.jsonl`, or a thread's `<sessionId>-topic-<thread>.jsonl`.
    public static string SessionID(string path) => Path.GetFileNameWithoutExtension(path);
}

/// The legacy `sessions.json` index beside the transcripts: `{"<sessionKey>": {sessionId, sessionFile, updatedAt, label,
/// displayName, spawnedBy, …}}`. Read again only when the file changes, at most 16 MB; one per file, shared by the agent's
/// readers (any tracker may ask, so the cache is locked as `CodexThreadNames` is).
public static class OpenClawSessionIndex
{
    static readonly object Gate = new();
    static readonly Dictionary<string, ((long, long, long) Stamp, Dictionary<string, OpenClawSessionFacts> Facts)> Cache = new(StringComparer.Ordinal);

    public static OpenClawSessionFacts? Facts(string transcript)
    {
        lock (Gate) return Read(transcript);
    }

    static OpenClawSessionFacts? Read(string transcript)
    {
        var index = Path.Combine(Path.GetDirectoryName(transcript) ?? "", "sessions.json");
        var file = LastComponent(transcript);
        var info = new FileInfo(index);
        if (!info.Exists)
        {
            Cache.Remove(index);
            return null;
        }
        var stamp = (info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks);
        if (Cache.TryGetValue(index, out var cached) && cached.Stamp == stamp) return cached.Facts.GetValueOrDefault(file);
        var facts = new Dictionary<string, OpenClawSessionFacts>(StringComparer.Ordinal);
        if (info.Length <= 16_777_216 && ReadAll(index) is { } data && Json.Parse(data) is { ValueKind: JsonValueKind.Object } entries)
        {
            var ids = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var property in entries.EnumerateObject())
                if (LogFields.Text(property.Value.Field("sessionId")) is { } sessionId) ids[property.Name] = sessionId;
            foreach (var property in entries.EnumerateObject())
            {
                var entry = property.Value;
                if (entry.ValueKind != JsonValueKind.Object || LogFields.Text(entry.Field("sessionId")) is not { } id) continue;
                var spawnedBy = LogFields.Text(entry.Field("spawnedBy"));
                var fact = OpenClawSessionFacts.Make(property.Name, entry.Field("label")?.Text, entry.Field("displayName")?.Text, spawnedBy,
                    LogFields.Text(entry.Field("spawnedBySessionId")) ?? (spawnedBy is not null ? ids.GetValueOrDefault(spawnedBy) : null),
                    LogFields.Milliseconds(entry.Field("updatedAt")), LogFields.Count(entry.Field("outputTokens")),
                    LogFields.Count(entry.Field("totalTokens")), entry.Field("totalTokensFresh")?.Bool == true,
                    LogFields.Count(entry.Field("contextTokens")), entry.Field("contextTokensSource")?.Text, entry.Field("model")?.Text,
                    entry.Field("spawnedWorkspaceDir")?.Text);
                var name = LogFields.Text(entry.Field("sessionFile")) is { } sessionFile ? LastComponent(sessionFile) : $"{id}.jsonl";
                // A key's newest entry wins when two name one file.
                if (facts.TryGetValue(name, out var existing)
                    && (existing.UpdatedAt ?? DateTimeOffset.MinValue) > (fact.UpdatedAt ?? DateTimeOffset.MinValue)) continue;
                facts[name] = fact;
            }
        }
        Cache[index] = (stamp, facts);
        return facts.GetValueOrDefault(file);
    }

    /// Windows and POSIX separators alike (rule 7).
    static string LastComponent(string path) => path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries) is [.., var last] ? last : path;

    static byte[]? ReadAll(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var data = new byte[stream.Length];
            stream.ReadExactly(data);
            return data;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }
}

// SQLite (v2026.8.1 on)

/// Reads one agent's `openclaw-agent.sqlite`, opened read-only (OpenClaw writes it in WAL mode).
/// - Re-queried when the database, its WAL or the WAL index header in `-shm` changed, and at least every 2 s while a session
///   is in a turn or updated within the hour (NTFS may report a file held open with stale times, rule 8); then the 64 most
///   recently updated `session_windows`, kept when among the newest 32, updated within the hour or in an open turn. A
///   session's entries are read by `seq`, only past the last one read (the first read takes its newest 256, plus the header
///   for its cwd); its entry facts are read again only when the node's `updated_at` moves. A read the database refused
///   (busy) is never cached.
/// - SQL selects only kinds, roles, times, model, stop reasons, usage counts and tool call ids and names (`json_extract`
///   inside SQLite, from `event_json` or a compressed row's `navigation_json`), so message text never reaches TokenCat.
public sealed class OpenClawDatabaseLog(string path) : ITokenLogReader
{
    public string Path { get; } = path;
    long[]? signature;
    DateTimeOffset? lastRead;
    Dictionary<string, Session> sessions = new(StringComparer.Ordinal);

    sealed class Session(string id)
    {
        public string Id { get; } = id;
        public OpenClawTurn State { get; set; } = new();
        public long? LastSeq { get; set; }
        public bool SkippedHead { get; set; }
        /// Window `updated_at`, `transcript_updated_at` and the node's `updated_at` at the last refresh.
        public long?[]? Stamp { get; set; }
        public long? NodeUpdated { get; set; }
        public OpenClawSessionFacts? Facts { get; set; }
        public string? WindowModel { get; set; }
        public DateTimeOffset Updated { get; set; } = DateTimeOffset.MinValue;
    }

    /// Which optional columns this store has: `session_nodes` arrived with agent schema 14, compressed rows with 23.
    sealed record Schema(bool Nodes, bool TranscriptUpdated, bool Navigation)
    {
        public static Schema? Of(OpenCodeDatabase database)
        {
            HashSet<string> Columns(string table)
            {
                var names = new HashSet<string>(StringComparer.Ordinal);
                database.Query($"SELECT name FROM pragma_table_info('{table}')", [], row => { if (row.Text(0) is { } name) names.Add(name); });
                return names;
            }
            var windows = Columns("session_windows");
            var nodes = Columns("session_nodes");
            var events = Columns("transcript_events");
            if (!windows.IsSupersetOf(["session_id", "session_key", "updated_at"])
                || !events.IsSupersetOf(["session_id", "seq", "event_json", "created_at"])) return null;
            return new Schema(nodes.IsSupersetOf(["session_key", "current_session_id", "entry_json", "updated_at"]),
                windows.Contains("transcript_updated_at"), events.Contains("navigation_json"));
        }
    }

    public void Read(int tailLimit, DateTimeOffset now)
    {
        foreach (var session in sessions.Values) session.State.Turn.Clamp(now.AddSeconds(5));
        if (OpenCodeDatabase.Signature(Path) is not { } current) return;
        var hot = sessions.Values.Any(session => session.State.IsOpen || (now - session.Updated).TotalSeconds <= 3_600);
        if (signature is not null && current.SequenceEqual(signature) && !(hot && lastRead is { } last && (now - last).TotalSeconds >= 2)) return;
        using var database = OpenCodeDatabase.Open(Path);
        if (database is null || !database.Execute("BEGIN")) return;
        try
        {
            if (Schema.Of(database) is not { } schema)
            {
                // A store without sessions (a schema-1 cache database, or one not migrated yet).
                sessions = new(StringComparer.Ordinal);
                signature = current;
                lastRead = now;
                return;
            }
            var listed = new List<(string Id, long?[] Stamp, long? Node)>();
            var node = schema.Nodes ? "n.updated_at" : "NULL";
            var join = schema.Nodes ? "LEFT JOIN session_nodes n ON n.session_key = w.session_key AND n.current_session_id = w.session_id" : "";
            var transcript = schema.TranscriptUpdated ? "w.transcript_updated_at" : "NULL";
            if (!database.Query($"SELECT w.session_id, w.updated_at, {transcript}, {node} FROM session_windows w {join} ORDER BY w.updated_at DESC LIMIT 64", [],
                    row => { if (row.Text(0) is { } id) listed.Add((id, [row.Int64(1), row.Int64(2), row.Int64(3)], row.Int64(3))); })) return;
            var kept = new Dictionary<string, Session>(StringComparer.Ordinal);
            var complete = true;
            for (var offset = 0; offset < listed.Count; offset++)
            {
                var row = listed[offset];
                sessions.TryGetValue(row.Id, out var existing);
                var newest = row.Stamp.Take(2).Where(value => value is not null).Select(value => value!.Value).DefaultIfEmpty(long.MinValue).Max();
                var updated = newest is > 0 and < 253_402_300_800_000 ? DateTimeOffset.FromUnixTimeMilliseconds(newest) : DateTimeOffset.MinValue;
                if (offset >= 32 && (now - updated).TotalSeconds > 3_600 && existing?.State.IsOpen != true) continue;
                var session = existing ?? new Session(row.Id);
                session.Updated = updated;
                if (session.Stamp is null || !session.Stamp.SequenceEqual(row.Stamp))
                {
                    if (Refresh(session, row.Node, schema, database)) session.Stamp = row.Stamp;
                    else
                    {
                        // Keeps what was read; a null stamp makes the next read refresh it again.
                        session.Stamp = null;
                        complete = false;
                    }
                }
                kept[row.Id] = session;
            }
            sessions = kept;
            signature = complete ? current : null;
            lastRead = now;
        }
        finally { database.Execute("COMMIT"); }
    }

    /// False when the database refused a read, or a burst filled the batch; what was read stays and the rest is read next.
    bool Refresh(Session session, long? node, Schema schema, OpenCodeDatabase database)
    {
        if (session.Stamp is null || session.NodeUpdated != node)
        {
            if (!ReadFacts(session, schema, database)) return false;
            session.NodeUpdated = node;
        }
        (long Low, long High)? bounds = null;
        if (!database.Query("SELECT min(seq), max(seq) FROM transcript_events WHERE session_id = ?", [session.Id],
                row => { if (row.Int64(0) is { } low && row.Int64(1) is { } high) bounds = (low, high); })) return false;
        if (bounds is not { } range) return true;
        // A rewind or cut that removed entries: read the session again.
        if (session.LastSeq is { } previous && range.High < previous)
        {
            session.State = new OpenClawTurn();
            session.LastSeq = null;
        }
        long start;
        if (session.LastSeq is { } last) start = last + 1;
        else
        {
            start = Math.Max(range.Low, range.High - 255);
            session.SkippedHead = start > range.Low;
            if (session.SkippedHead && !ReadHeader(session, range.Low, database)) return false;
        }
        if (start > range.High)
        {
            session.State.Settle(session.Facts);
            return true;
        }
        var events = new List<(long Seq, OpenClawEvent Event)>();
        if (!database.Query(EventsQuery(schema.Navigation, start), [session.Id],
                row => { if (row.Int64(0) is { } seq) events.Add((seq, Event(row))); })) return false;
        foreach (var entry in events)
        {
            session.State.Consume(entry.Event, session.SkippedHead);
            session.LastSeq = entry.Seq;
        }
        session.State.Settle(session.Facts);
        return events.Count < 2_048;
    }

    static bool ReadHeader(Session session, long low, OpenCodeDatabase database) =>
        database.Query($"""
            SELECT json_extract(j, '$.type'), json_extract(j, '$.id'), json_extract(j, '$.cwd')
            FROM (SELECT CASE WHEN json_valid(event_json) THEN event_json END AS j FROM transcript_events WHERE session_id = ? AND seq = {low})
            """, [session.Id], row => session.State.Identify(new OpenClawEvent
        {
            Type = row.Text(0),
            SessionID = row.Text(1),
            Cwd = row.Text(2) is { Length: <= 4_096 } cwd ? cwd : null,
        }));

    static bool ReadFacts(Session session, Schema schema, OpenCodeDatabase database)
    {
        if (!schema.Nodes)
            return database.Query("SELECT model FROM session_windows WHERE session_id = ?", [session.Id], row => session.WindowModel = row.Text(0));
        // The parent: the session id captured at spawn, else the spawning key's current session in this store.
        return database.Query("""
            SELECT key, model, updated, substr(json_extract(j, '$.label'), 1, 4096), substr(json_extract(j, '$.displayName'), 1, 4096),
                   json_extract(j, '$.spawnedBy'),
                   coalesce(json_extract(j, '$.spawnedBySessionId'),
                            (SELECT p.current_session_id FROM session_nodes p WHERE p.session_key = json_extract(j, '$.spawnedBy'))),
                   json_extract(j, '$.outputTokens'), json_extract(j, '$.totalTokens'), json_extract(j, '$.totalTokensFresh'),
                   json_extract(j, '$.contextTokens'), json_extract(j, '$.contextTokensSource'), json_extract(j, '$.model'),
                   substr(json_extract(j, '$.spawnedWorkspaceDir'), 1, 4097)
            FROM (SELECT w.session_key AS key, w.model AS model, n.updated_at AS updated,
                         CASE WHEN json_valid(n.entry_json) THEN n.entry_json END AS j
                  FROM session_windows w
                  LEFT JOIN session_nodes n ON n.session_key = w.session_key AND n.current_session_id = w.session_id
                  WHERE w.session_id = ?)
            """, [session.Id], row =>
        {
            session.WindowModel = row.Text(1);
            session.Facts = OpenClawSessionFacts.Make(row.Text(0), row.Text(3), row.Text(4), row.Text(5), row.Text(6), row.Date(2),
                OpenClawLog.Count(row.Int64(7)), OpenClawLog.Count(row.Int64(8)), row.Int64(9) == 1, OpenClawLog.Count(row.Int64(10)),
                row.Text(11), row.Text(12), row.Text(13));
        });
    }

    /// One row per entry from `start`, at most 2,048 per read. A compressed row (`event_json` NULL) answers from its
    /// navigation facts (`$.model…`, the same paths), which hold no usage.
    static string EventsQuery(bool navigation, long start)
    {
        string Field(string path) => navigation
            ? $"CASE WHEN j IS NOT NULL THEN json_extract(j, '${path}') ELSE json_extract(n, '$.model{path}') END"
            : $"json_extract(j, '${path}')";
        var source = navigation ? "CASE WHEN event_json IS NULL AND json_valid(navigation_json) THEN navigation_json END AS n" : "NULL AS n";
        var contentPath = navigation ? "CASE WHEN j IS NOT NULL THEN '$.message.content' ELSE '$.model.message.content' END" : "'$.message.content'";
        var idempotency = navigation
            ? "coalesce(json_extract(j, '$.message.idempotencyKey'), json_extract(n, '$.navigation.message.idempotencyKey'))"
            : "json_extract(j, '$.message.idempotencyKey')";
        return $"""
            SELECT seq, created_at, {Field(".type")}, {Field(".timestamp")}, {Field(".message.role")}, {Field(".message.timestamp")},
                   {Field(".message.provider")}, {Field(".message.model")}, json_extract(j, '$.message.api'),
                   json_extract(j, '$.message.openclawDeliveryMirror.kind'), {Field(".message.stopReason")}, json_extract(j, '$.message.endTurn'),
                   json_extract(j, '$.message.usage.output'), json_extract(j, '$.message.usage.input'),
                   json_extract(j, '$.message.usage.cacheRead'), json_extract(j, '$.message.usage.cacheWrite'),
                   {Field(".message.toolCallId")},
                   CASE WHEN {Field(".message.role")} = 'assistant' THEN
                       (SELECT json_group_array(json_array(json_extract(c.value, '$.id'), json_extract(c.value, '$.name')))
                        FROM json_each(coalesce(j, n), {contentPath}) AS c
                        WHERE CASE WHEN c.type = 'object' THEN json_extract(c.value, '$.type') END IN ('toolCall', 'toolUse', 'functionCall'))
                   END,
                   substr({idempotency}, 1, 17) = 'codex-app-server:',
                   {Field(".modelId")}, {Field(".customType")}, json_extract(j, '$.data.modelId'), json_extract(j, '$.id'),
                   substr(json_extract(j, '$.cwd'), 1, 4097), j IS NOT NULL
            FROM (SELECT seq, created_at, CASE WHEN json_valid(event_json) THEN event_json END AS j, {source}
                  FROM transcript_events WHERE session_id = ? AND seq >= {start} ORDER BY seq LIMIT 2048)
            """;
    }

    /// Columns of `EventsQuery`, in order.
    static OpenClawEvent Event(OpenCodeDatabase.Row row)
    {
        var result = new OpenClawEvent
        {
            Type = row.Text(2),
            At = LogFields.Date(row.Text(3)) ?? row.Date(1),
            Role = row.Text(4),
            StartedAt = row.Date(5),
            ToolCallID = row.Text(16),
        };
        switch (result.Type)
        {
            case "session":
                result.SessionID = row.Text(22);
                result.Cwd = row.Text(23) is { Length: > 0 and <= 4_096 } cwd ? cwd : null;
                break;
            case "model_change":
                result.ModelChange = row.Text(19);
                break;
            case "custom" when row.Text(20) == "model-snapshot":
                result.ModelChange = row.Text(21);
                break;
        }
        if (result.Role != "assistant") return result;
        result.Provider = row.Text(6);
        result.Model = row.Text(7);
        result.Api = row.Text(8);
        result.MirrorKind = row.Text(9);
        result.StopReason = row.Text(10);
        result.EndTurn = row.Int64(11) is { } endTurn ? endTurn != 0 : null;
        result.CodexMirror = row.Int64(18) == 1;
        // Usage is readable only from an uncompressed row.
        if (row.Int64(24) == 1)
        {
            result.Output = OpenClawLog.Count(row.Int64(12)) ?? 0;
            result.Context = new[] { 13, 14, 15 }.Aggregate(0, (sum, column) => LogFields.Add(sum, OpenClawLog.Count(row.Int64(column)) ?? 0));
        }
        if (row.Text(17) is { } calls && Json.Parse(Encoding.UTF8.GetBytes(calls)) is { ValueKind: JsonValueKind.Array } list)
            foreach (var call in list.EnumerateArray())
                if (call.ValueKind == JsonValueKind.Array && call.GetArrayLength() == 2 && LogFields.Text(call[0]) is { } id)
                    result.ToolCalls.Add((id, TokenLogParser.Label(call[1])));
        return result;
    }

    public bool IsRecent(DateTimeOffset now) =>
        sessions.Values.Any(session => session.State.IsOpen || (now - session.Updated).TotalSeconds <= 3_600 || session.State.Turn.IsRecent(now));

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        var readings = new List<TokenReading>();
        foreach (var session in sessions.Values)
        {
            if (session.State.Reading($"{id}#{session.Id}", session.Facts, session.WindowModel, now) is not { } reading) continue;
            reading = reading with { SessionID = session.Id };
            if (reading.IsSubagent) reading = reading with { AgentID = session.Id };
            readings.Add(reading);
        }
        return readings;
    }
}
