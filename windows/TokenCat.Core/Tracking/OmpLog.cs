using System.Text;
using System.Text.Json;

namespace TokenCat;

/// OmpLog.swift: omp and Pi coding-agent sessions, `<root>\<encoded cwd>\<timestamp>_<id>.jsonl`, with subagent sessions nested in
/// the session's folder (`<timestamp>_<id>\<Agent>.jsonl`, then `<Agent>\<Agent.Child>.jsonl`). Append-only JSONL read through
/// `LogLineTail`. Only the session header, model and thinking level, message roles, usage counts, the client's own request
/// timing (`duration`, `ttft`), stop reasons and tool names survive; message content is never kept.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Omp = new(OmpFiles, path => path.EndsWith(".jsonl", StringComparison.Ordinal),
        path => new OmpLogReader(path));

    static List<string> OmpFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var main = new List<FileSystemInfo>();
        var subagents = new List<FileSystemInfo>();
        void Nested(string folder, int depth)
        {
            foreach (var entry in TokenDiscovery.Children(folder))
            {
                if (entry is FileInfo && entry.Name.EndsWith(".jsonl", StringComparison.Ordinal)) subagents.Add(entry);
                else if (depth > 0 && entry is DirectoryInfo) Nested(entry.FullName, depth - 1);
            }
        }
        foreach (var project in roots.SelectMany(TokenDiscovery.Children))
            foreach (var entry in TokenDiscovery.Children(project.FullName))
            {
                if (entry is FileInfo && entry.Name.EndsWith(".jsonl", StringComparison.Ordinal)) main.Add(entry);
                else if (entry is DirectoryInfo) Nested(entry.FullName, 2);
            }
        // Subagents come in bursts; they get their own cap so main sessions stay visible.
        return [.. discovery.Recent(main), .. discovery.Recent(subagents, discovery.Now.UtcDateTime.AddHours(-1))];
    }
}

sealed class OmpLogReader(string path) : ITokenLogReader
{
    readonly LogLineTail tail = new(path);
    OmpLogState state = new(path);
    bool headerRead;
    /// Pi's own sessions (`~\.pi\agent\sessions`); null for omp.
    readonly string? clientName = path.Replace('\\', '/').Contains("/.pi/agent/", StringComparison.OrdinalIgnoreCase) ? "Pi" : null;

    public void Read(int tailLimit, DateTimeOffset now)
    {
        tail.Read(tailLimit, () =>
        {
            state = new OmpLogState(path);
            headerRead = false;
        }, line => state.Consume(line, tail.SkippedHead));
        // The header (a title line, then the session line) is lost when the first read starts mid-file.
        if (!tail.SkippedHead || headerRead) return;
        try
        {
            using var handle = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, bufferSize: 0);
            // Set once the file opened, as in Swift: a failed open is tried again on the next read.
            headerRead = true;
            var head = new byte[(int)Math.Min(65_536, handle.Length)];
            var read = handle.ReadAtLeast(head, head.Length, throwOnEndOfStream: false);
            var start = 0;
            for (var count = 0; count < 8 && start < read && Array.IndexOf(head, (byte)10, start, read - start) is var newline and >= 0; count++)
            {
                state.ConsumeHeader(head[start..newline]);
                start = newline + 1;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        var s = state;
        if (s.LastActivity is not { } lastActivity) return [];
        var tool = s.RunningTool;
        return [new TokenReading(TokenSource.Omp, id)
        {
            ClientName = clientName,
            SessionID = s.SessionID,
            ParentSessionID = s.ParentSessionID,
            AgentID = s.AgentID,
            IsSubagent = s.IsSubagent,
            AgentRole = s.AgentRole,
            Project = s.Cwd is { } cwd ? LastComponent(cwd) : null,
            ProjectPath = s.Cwd,
            Model = s.Model,
            Effort = s.Effort,
            Context = s.Context,
            LastActivity = lastActivity,
            LastLogAt = s.LastLogAt,
            MeasurementAt = s.Completion?.At ?? lastActivity,
            Active = s.IsActive(now),
            ActivityState = s.ActivityState(now),
            ToolName = tool,
            ToolCategory = tool is null ? null : OmpLogState.Category(tool),
            CurrentTurnStartedAt = s.Open ? s.TurnStartedAt : null,
            CurrentTurnOutputTokens = s.Open && s.TurnStartedAt is not null ? s.TurnOutput : null,
            LastOutputAt = s.Events.Count > 0 ? s.Events[^1].At : null,
            LastOutputDelta = s.Events.Count > 0 ? s.Events[^1].Tokens : null,
            RecentOutputs = [.. s.Events.Where(e => (now - e.At).TotalSeconds is >= -5 and <= TokenTracker.RecentOutputWindow)],
            SpeedMeasurement = s.Measurement,
            LastOutputTokens = s.Completion?.Output,
            SampledAt = now,
        }];
    }

    public bool IsRecent(DateTimeOffset now) =>
        state.Open || new[] { state.LastLogAt, state.LastActivity }.Max() is { } live && (now - live).TotalSeconds <= 3_600;

    static string LastComponent(string cwd) =>
        cwd.Replace('\\', '/').TrimEnd('/') is var trimmed && trimmed.LastIndexOf('/') is var slash and >= 0 && slash < trimmed.Length - 1
            ? trimmed[(slash + 1)..] : cwd;
}

/// Turn state of one omp or Pi session log.
sealed class OmpLogState
{
    public string? SessionID { get; private set; }
    public string? ParentSessionID { get; }
    public string? AgentID { get; }
    public bool IsSubagent { get; }
    public string? AgentRole { get; private set; }
    public string? Cwd { get; private set; }
    public string? Model { get; private set; }
    public string? Effort { get; private set; }
    public TokenContextUsage? Context { get; private set; }
    public DateTimeOffset? LastActivity { get; private set; }
    public DateTimeOffset? LastLogAt { get; private set; }
    public bool Open { get; private set; }
    public DateTimeOffset? TurnStartedAt { get; private set; }
    public int TurnOutput { get; private set; }
    public (int Output, DateTimeOffset At)? Completion { get; private set; }
    public List<TokenOutputEvent> Events { get; } = [];
    public TokenSpeedMeasurement? Measurement { get; private set; }
    TokenActivityState observed = TokenActivityState.Idle;
    bool sawContent;
    /// Outstanding tool calls in call order, id → name. Arguments are never read.
    readonly List<(string Id, string Name)> pendingTools = [];

    /// A subagent lives in its root session's folder (`<timestamp>_<root id>\…`); that id groups it under the root. The agent
    /// id keeps a slash so the row is titled by the agent's own name (the file name, e.g. `Scout` or `Scout.Helper`).
    public OmpLogState(string path)
    {
        var folders = (Path.GetDirectoryName(path) ?? "").Replace('\\', '/').Split('/');
        var rootID = folders.Reverse().Select(SessionFileID).FirstOrDefault(id => id is not null);
        IsSubagent = rootID is not null;
        ParentSessionID = rootID;
        AgentID = rootID is null ? null : $"{rootID}/{Path.GetFileNameWithoutExtension(path)}";
    }

    /// The id in a session file or folder name such as `2026-10-06T07-17-38-289Z_<id>`.
    static string? SessionFileID(string name) =>
        name.Length > 25 && name[..4].All(char.IsAsciiDigit) && name[10] == 'T' && name.IndexOf('_') is var separator and >= 0
        && separator < name.Length - 1 ? name[(separator + 1)..] : null;

    /// Identity records only, for a header the tail skipped: never usage, turns or times.
    public void ConsumeHeader(byte[] line)
    {
        if (Parse(line) is not { } document) return;
        using (document) ConsumeIdentity(document.RootElement);
    }

    public void Consume(byte[] line, bool headSkipped)
    {
        if (OmpRecordHead.Scan(line) is { } head && ConsumeHead(head, headSkipped)) return;
        if (Parse(line) is not { } document) return;
        using (document)
        {
            var record = document.RootElement;
            var at = LogFields.Date(record.Field("timestamp"));
            if (at is { } stamp) LastLogAt = Later(LastLogAt, stamp);
            ConsumeIdentity(record);
            switch (record.Field("type")?.Text)
            {
                case "model_change":
                    // "provider/model"; assistant messages name the model alone.
                    if (Model is null && LogFields.Text(record.Field("model")) is { } value) Model = value[(value.IndexOf('/') + 1)..];
                    break;
                case "thinking_level_change":
                    Effort = TokenLogParser.Label(record.Field("thinkingLevel")) ?? Effort;
                    break;
                case "message":
                    if (record.Field("message") is { ValueKind: JsonValueKind.Object } message)
                        ConsumeMessage(message, at ?? LogFields.Milliseconds(message.Field("timestamp")), headSkipped);
                    break;
                case "custom" when record.Field("customType")?.Text == "session_exit":
                    if (!Open) break;
                    Open = false;
                    var normal = record.Field("data")?.Field("kind")?.Text == "normal";
                    observed = normal ? TokenActivityState.Complete : TokenActivityState.Interrupted;
                    if (normal && at is { } exit && TurnStartedAt is not null) Completion = (TurnOutput, exit);
                    pendingTools.Clear();
                    break;
            }
        }
    }

    /// Records whose kept fields all sit in the head, so the body (tool output, file contents, notices) is never decoded:
    /// tool results, other message roles, and record types that only stamp `LastLogAt`. False leaves the line to the full parse.
    bool ConsumeHead(OmpRecordHead head, bool headSkipped)
    {
        switch (head.Fields.GetValueOrDefault("type"))
        {
            case null or "session" or "session_init" or "model_change" or "thinking_level_change":
                return false;
            case "custom" when (head.Fields.GetValueOrDefault("customType") ?? "session_exit") == "session_exit":
                return false;
            case "message":
                if (head.Message.GetValueOrDefault("role") is not { } role || role is "user" or "assistant"
                    || head.Fields.GetValueOrDefault("timestamp") is not { } stamp
                    || (role == "toolResult" && !head.Message.ContainsKey("toolCallId"))) return false;
                if (LogFields.Date(stamp) is not { } at) return role != "toolResult";
                LastLogAt = Later(LastLogAt, at);
                if (role == "toolResult") ConsumeToolResult(head.Message["toolCallId"] is { Length: > 0 } id ? id : null, at, headSkipped);
                return true;
            default:
                if ((head.Fields.GetValueOrDefault("timestamp") ?? head.TrailingTimestamp) is not { } text) return false;
                if (LogFields.Date(text) is { } logged) LastLogAt = Later(LastLogAt, logged);
                return true;
        }
    }

    /// Subagent status comes from the folder nesting alone: `/fork` and branched sessions also name a `parentSession`, but
    /// they are top-level conversations of their own.
    void ConsumeIdentity(JsonElement record)
    {
        switch (record.Field("type")?.Text)
        {
            case "session":
                SessionID = LogFields.Text(record.Field("id")) ?? SessionID;
                if (LogFields.Text(record.Field("cwd")) is { Length: <= 4_096 } cwd) Cwd = cwd;
                break;
            case "session_init":
                AgentRole = TokenLogParser.Label(record.Field("agent")) ?? AgentRole;
                break;
        }
    }

    void ConsumeMessage(JsonElement message, DateTimeOffset? stamp, bool headSkipped)
    {
        if (stamp is not { } at) return;
        var role = message.Field("role")?.Text;
        if (role == "toolResult")
        {
            ConsumeToolResult(LogFields.Text(message.Field("toolCallId")), at, headSkipped);
            return;
        }
        if (role is not ("user" or "assistant")) return;
        // A tail that starts inside a turn has not seen its prompt, so that turn's output is unknown.
        var unseenStart = headSkipped && !sawContent;
        sawContent = true;
        switch (role)
        {
            case "user":
                LastActivity = Later(LastActivity, at);
                // A steering message joins the running turn.
                if (!Open) OpenTurn(at);
                observed = TokenActivityState.Working;
                break;
            case "assistant":
                var finished = LogFields.Milliseconds(message.Field("completedAt")) ?? at;
                LastActivity = Later(LastActivity, finished);
                if (!Open) OpenTurn(unseenStart ? null : LogFields.Milliseconds(message.Field("timestamp")) ?? at);
                if (LogFields.Text(message.Field("model")) is { Length: <= 128 } name) Model = name;
                var usage = message.Field("usage");
                var output = LogFields.Count(usage?.Field("output")) ?? 0;
                if (output > 0)
                {
                    TurnOutput = LogFields.Add(TurnOutput, output);
                    Events.Add(new TokenOutputEvent(finished, output));
                    if (Events.Count > 512) Events.RemoveRange(0, Events.Count - 512);
                }
                var used = new[] { "input", "cacheRead", "cacheWrite" }.Aggregate(0, (sum, key) => LogFields.Add(sum, LogFields.Count(usage?.Field(key)) ?? 0));
                if (used > 0) Context = new TokenContextUsage(used, null, finished, null);
                var stop = message.Field("stopReason")?.Text;
                // The client's own timing of this request (start to completion, first token included); never log times.
                if (output > 0 && stop is not ("aborted" or "error") && Milliseconds(message.Field("duration")) is { } duration and > 0)
                    Measurement = new TokenSpeedMeasurement
                    {
                        Model = Model, At = finished, OutputTokens = output, RequestDurationMs = duration,
                        TtftMs = Milliseconds(message.Field("ttft")),
                    };
                foreach (var block in LogFields.Objects(message.Field("content")))
                {
                    if (block.Field("type")?.Text != "toolCall" || LogFields.Text(block.Field("id")) is not { } id) continue;
                    pendingTools.RemoveAll(tool => tool.Id == id);
                    pendingTools.Add((id, TokenLogParser.Label(block.Field("name")) ?? "tool"));
                    if (pendingTools.Count > 256) pendingTools.RemoveRange(0, pendingTools.Count - 256);
                }
                switch (stop)
                {
                    case "stop" or "length":
                        if (TurnStartedAt is not null) Completion = (TurnOutput, finished);
                        CloseTurn(TokenActivityState.Complete);
                        break;
                    case "aborted" or "error":
                        CloseTurn(TokenActivityState.Interrupted);
                        break;
                    default:
                        observed = pendingTools.Count == 0 ? TokenActivityState.Working : TokenActivityState.Tool;
                        break;
                }
                break;
        }
    }

    void ConsumeToolResult(string? callID, DateTimeOffset at, bool headSkipped)
    {
        var unseenStart = headSkipped && !sawContent;
        sawContent = true;
        LastActivity = Later(LastActivity, at);
        if (!Open) OpenTurn(unseenStart ? null : at);
        if (callID is not null) pendingTools.RemoveAll(tool => tool.Id == callID);
        observed = pendingTools.Count == 0 ? TokenActivityState.Working : TokenActivityState.Tool;
    }

    void OpenTurn(DateTimeOffset? start)
    {
        Open = true;
        TurnStartedAt = start;
        TurnOutput = 0;
        pendingTools.Clear();
    }

    void CloseTurn(TokenActivityState state)
    {
        Open = false;
        observed = state;
        pendingTools.Clear();
    }

    static DateTimeOffset Later(DateTimeOffset? current, DateTimeOffset value) => current is { } existing && existing > value ? existing : value;

    static double? Milliseconds(JsonElement? value) => value?.Number is { } ms && ms >= 0 && ms <= 604_800_000 ? ms : null;

    static JsonDocument? Parse(byte[] line)
    {
        try { return JsonDocument.Parse(line, Json.Depth); }
        catch (JsonException) { return null; }
    }

    /// omp's `ask` tool waits for the person.
    bool WaitsForInput => Open && pendingTools.Any(tool => tool.Name == "ask");

    public string? RunningTool => !Open ? null
        : pendingTools.FindLast(tool => tool.Name == "ask") is { Name: not null } asking ? asking.Name
        : pendingTools.Count > 0 ? pendingTools[^1].Name : null;

    /// How long an open turn may stay silent and still count as running. Subagent tools (`task`, `wait`) block for as
    /// long as their agents run; a question waits for the person.
    double LiveHorizon => WaitsForInput ? 86_400
        : pendingTools.Count == 0 ? 600
        : Category(pendingTools[^1].Name) == ToolCategory.Agent ? 3_600 : 900;

    DateTimeOffset? LiveAt => new[] { LastLogAt, LastActivity }.Max();

    public bool IsActive(DateTimeOffset now) =>
        Open && LiveAt is { } live && (now - live).TotalSeconds is var age && age >= -5 && age <= LiveHorizon;

    public TokenActivityState ActivityState(DateTimeOffset now)
    {
        if (!Open) return observed;
        if (WaitsForInput) return IsActive(now) ? TokenActivityState.Input : TokenActivityState.Unfinished;
        if (IsActive(now)) return observed;
        return LiveAt is { } live && (now - live).TotalSeconds <= 1_800 ? TokenActivityState.Stale : TokenActivityState.Unfinished;
    }

    /// omp and Pi name their tools in lower case.
    public static ToolCategory Category(string name) => name.StartsWith("mcp_", StringComparison.Ordinal) ? ToolCategory.Mcp : name switch
    {
        "bash" or "eval" or "python" or "shell" or "exec" => ToolCategory.Command,
        "read" or "write" or "edit" or "glob" or "grep" or "find" or "ls" or "ast_edit" or "ast_grep" or "notebook" => ToolCategory.File,
        "web_search" or "web_fetch" or "fetch" or "browser" => ToolCategory.Web,
        "task" or "wait" or "yield" or "agent" => ToolCategory.Agent,
        "ask" => ToolCategory.Question,
        _ => TokenLogParser.Category(name),
    };
}

/// OmpRecordHead (OmpLog.swift): the plain string fields at the start of an omp record, read without decoding the rest of the
/// line: top-level fields up to the first nested value, then the same inside `message` (`role`, `toolCallId` precede
/// `content`), and a `timestamp` that closes the line (`custom` records stamp after their `data`). Numbers, nulls and escaped
/// strings are skipped, so a field the caller needs may be missing; it then parses the whole line. Null when the line is not
/// an object.
sealed record OmpRecordHead(Dictionary<string, string> Fields, Dictionary<string, string> Message, string? TrailingTimestamp)
{
    const int Limit = 1_024;
    static readonly byte[] TimestampKey = ",\"timestamp\":\""u8.ToArray();

    public static OmpRecordHead? Scan(byte[] line)
    {
        var end = Math.Min(line.Length, Limit);
        var index = 0;
        void SkipSpace() { while (index < end && line[index] is (byte)' ' or (byte)'\t') index++; }
        // The string opening at `index`: false past the limit; `value` null when it holds an escape (skipped, not kept).
        bool ReadString(out string? value)
        {
            value = null;
            var cursor = index + 1;
            var escaped = false;
            while (cursor < end && line[cursor] != '"')
            {
                if (line[cursor] == '\\') { escaped = true; cursor++; }
                cursor++;
            }
            if (cursor >= end) return false;
            if (!escaped) value = Encoding.UTF8.GetString(line, index + 1, cursor - index - 1);
            index = cursor + 1;
            return true;
        }
        // The string fields of the object opening at `index`, up to its first nested value or the limit. `nested` is true
        // when that value is the object under `message`.
        Dictionary<string, string>? Object(out bool nested)
        {
            nested = false;
            if (index >= end || line[index] != '{') return null;
            index++;
            var fields = new Dictionary<string, string>(StringComparer.Ordinal);
            while (true)
            {
                SkipSpace();
                if (index >= end || line[index] != '"' || !ReadString(out var key)) return fields;
                SkipSpace();
                if (index >= end || line[index] != ':') return fields;
                index++;
                SkipSpace();
                if (index >= end) return fields;
                switch (line[index])
                {
                    case (byte)'"':
                        if (!ReadString(out var value)) return fields;
                        if (key is not null && value is not null) fields[key] = value;
                        break;
                    case (byte)'{':
                        nested = key == "message";
                        return fields;
                    case (byte)'[':
                        return fields;
                    default:
                        while (index < end && line[index] is not ((byte)',' or (byte)'}')) index++;
                        break;
                }
                SkipSpace();
                if (index >= end || line[index] != ',') return fields;
                index++;
            }
        }
        if (Object(out var nested) is not { } top) return null;
        var message = new Dictionary<string, string>(StringComparer.Ordinal);
        if (nested)
        {
            if (Object(out _) is not { } inner) return null;
            message = inner;
        }
        // `,"timestamp":"<value>"}` ending the line is a top-level key: inside a nested object the line would end in `}}`.
        var last = line.Length;
        while (last > 0 && line[last - 1] is (byte)' ' or (byte)'\t' or (byte)'\r') last--;
        if (last < 2 || line[last - 1] != '}' || line[last - 2] != '"') return new(top, message, null);
        var open = last - 3;
        while (open >= 0 && last - open < 64 && line[open] is not ((byte)'"' or (byte)'\\')) open--;
        if (open < TimestampKey.Length - 1 || line[open] != '"'
            || !line.AsSpan(open - TimestampKey.Length + 1, TimestampKey.Length).SequenceEqual(TimestampKey)) return new(top, message, null);
        return new(top, message, Encoding.UTF8.GetString(line, open + 1, last - 2 - open - 1));
    }
}
