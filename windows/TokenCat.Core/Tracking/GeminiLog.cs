using System.Globalization;
using System.Text.Json;

namespace TokenCat;

// Gemini CLI and Qwen Code (a Gemini CLI fork) chat logs; mirrors the mac's Providers/GeminiLog.swift. Only ids, counts,
// times, statuses, tool and model names are read; message text, tool arguments and results never leave the parsed record.
// Neither client logs when generation started or ended, so no speed is ever derived from these logs; a measured speed comes
// only from the client's own telemetry (`api_response`, TelemetryDecode.cs) once TelemetrySetup connected it, joined to
// these rows by session ID.

/// The output count rule both the chat logs and the telemetry `api_response` use.
public static class GeminiTokens
{
    /// Output = candidates, plus thoughts when the total shows they were counted apart (Gemini API). OpenAI-compatible
    /// providers already include reasoning in the candidates, so it is not added twice.
    public static int Output(int? candidates, int? thoughts, int? prompt, int? total)
    {
        var count = candidates ?? 0;
        return thoughts is > 0 && total is { } sum && (long)sum >= (long)(prompt ?? 0) + count + thoughts.Value ? LogFields.Add(count, thoughts.Value) : count;
    }
}

public sealed partial record TokenLogFormat
{
    /// `<root>\<project>\chats\session-*.jsonl` (legacy `session-*.json` snapshots until resumed), and subagents in
    /// `chats\<parent session id>\<session id>.jsonl`. The project folder holds `.project_root` with the project path.
    public static readonly TokenLogFormat Gemini = new(GeminiFiles, path =>
    {
        var parts = path.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3) return false;
        var name = parts[^1];
        if (parts[^2] == "chats")
            return name.StartsWith("session-", StringComparison.Ordinal)
                && (name.EndsWith(".jsonl", StringComparison.Ordinal) || name.EndsWith(".json", StringComparison.Ordinal));
        return parts[^3] == "chats" && name.EndsWith(".jsonl", StringComparison.Ordinal);
    }, path => new GeminiChatReader(path));

    /// `<root>\<project>\chats\<session id>.jsonl`, and background subagents in
    /// `<root>\<project>\subagents\<session id>\agent-<id>.jsonl` beside an `agent-<id>.meta.json` sidecar.
    public static readonly TokenLogFormat Qwen = new(QwenFiles, path =>
    {
        var parts = path.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3 || !parts[^1].EndsWith(".jsonl", StringComparison.Ordinal)) return false;
        return parts[^2] == "chats" || (parts[^1].StartsWith("agent-", StringComparison.Ordinal) && parts[^3] == "subagents");
    }, path => new QwenChatReader(path));

    static List<string> GeminiFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var main = new List<FileSystemInfo>();
        var subagents = new List<FileSystemInfo>();
        foreach (var project in roots.SelectMany(TokenDiscovery.Children))
        {
            var entries = TokenDiscovery.Children(Path.Combine(project.FullName, "chats"));
            var jsonl = entries.Where(IsJsonl).Select(entry => entry.Name).ToHashSet(StringComparer.Ordinal);
            // A resumed legacy snapshot is migrated to `<name>.jsonl` and left in place; only the migrated log counts.
            main.AddRange(entries.Where(entry => entry is FileInfo && entry.Name.StartsWith("session-", StringComparison.Ordinal)
                && (IsJsonl(entry) || (Path.GetExtension(entry.Name) == ".json" && !jsonl.Contains(entry.Name + "l")))));
            foreach (var parent in entries.Where(entry => entry is DirectoryInfo && HasNoExtension(entry)))
                subagents.AddRange(TokenDiscovery.Children(parent.FullName).Where(IsJsonl));
        }
        return [.. discovery.Recent(main), .. discovery.Recent(subagents, discovery.Now.UtcDateTime.AddHours(-1))];
    }

    static List<string> QwenFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var main = new List<FileSystemInfo>();
        var subagents = new List<FileSystemInfo>();
        foreach (var project in roots.SelectMany(TokenDiscovery.Children))
        {
            main.AddRange(TokenDiscovery.Children(Path.Combine(project.FullName, "chats")).Where(IsJsonl));
            foreach (var session in TokenDiscovery.Children(Path.Combine(project.FullName, "subagents")).Where(HasNoExtension))
                subagents.AddRange(TokenDiscovery.Children(session.FullName)
                    .Where(entry => IsJsonl(entry) && entry.Name.StartsWith("agent-", StringComparison.Ordinal)));
        }
        return [.. discovery.Recent(main), .. discovery.Recent(subagents, discovery.Now.UtcDateTime.AddHours(-1))];
    }
}

/// Turn bookkeeping shared by both clients. Neither writes an explicit turn end in an interactive session, so a reply
/// without a tool call closes the turn softly: a later tool record or tool result in the same turn reopens it.
file sealed class ChatTurnState(TokenSource source)
{
    public TokenSource Source { get; } = source;
    public string? SessionID { get; set; }
    public string? ParentSessionID { get; set; }
    public string? AgentID { get; set; }
    public string? AgentRole { get; set; }
    public string? Project { get; set; }
    public string? ProjectPath { get; set; }
    public string? Model { get; set; }
    public bool IsSubagent { get; set; }
    public DateTimeOffset? LastActivity { get; private set; }
    public DateTimeOffset? LastLogAt { get; private set; }
    public TokenTurnCompletion? Completion { get; private set; }
    TokenContextUsage? contextUsage;
    DateTimeOffset? compactedAt;
    bool open;
    DateTimeOffset? startedAt;
    /// The message that began the open turn: a rollback that removes it cancelled the turn.
    public string? TurnMessageID { get; private set; }
    /// The person's input of the current turn was read, so its output count is complete.
    bool startSeen;
    int output;
    bool turnHasOutput;
    TokenActivityState observedState = TokenActivityState.Idle;
    /// Outstanding tool calls in call order, id → name. Inputs are never read.
    readonly List<(string Id, string? Name)> tools = [];
    /// Gemini: a reply that asked for tools the client records only once they finish.
    bool unnamedTool;
    DateTimeOffset? lastOutputAt;
    int? lastOutputDelta;
    readonly List<TokenOutputEvent> recentOutputs = [];
    /// Output already counted per message: Gemini appends a message again when its tokens or tool calls arrive.
    readonly Dictionary<string, int> counted = new(StringComparer.Ordinal);
    /// Tools that wait for the person (Qwen's question and plan approval; Gemini's ask_user).
    static readonly HashSet<string> InputTools = new(["ask_user_question", "ask_user", "exit_plan_mode"], StringComparer.Ordinal);

    public bool HasTools => tools.Count > 0;
    public bool IsOpen => open;

    /// Whether a record at `date` still belongs to the open turn: it came within the turn's liveness horizon. Read before
    /// the record is noted.
    public bool Continues(DateTimeOffset? date) =>
        open && (date is not { } at || LiveAt is not { } live || (at - live).TotalSeconds <= LiveHorizon);

    public void SetProject(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;
        Project = path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries) is [.., var last] ? last : path;
        ProjectPath = path;
    }

    /// A record of any kind: liveness only.
    public void Note(DateTimeOffset? date)
    {
        if (date is { } at && (LastLogAt is not { } last || at > last)) LastLogAt = at;
    }

    /// A content record: shown as activity.
    public void Touch(DateTimeOffset? date)
    {
        if (date is not { } at) return;
        if (LastActivity is not { } last || at > last) LastActivity = at;
        Note(at);
    }

    public void Clamp(DateTimeOffset latest)
    {
        if (LastLogAt > latest) LastLogAt = latest;
        if (LastActivity > latest) LastActivity = latest;
    }

    /// The person's input starts a turn.
    public void Begin(DateTimeOffset? date, string? message = null)
    {
        open = true;
        startedAt = date;
        TurnMessageID = message;
        startSeen = date is not null;
        output = 0;
        turnHasOutput = false;
        tools.Clear();
        unnamedTool = false;
        observedState = TokenActivityState.Working;
        lastOutputAt = null;
        lastOutputDelta = null;
        Touch(date);
    }

    /// A record that continues the turn (tool calls, tool results, thoughts); reopens a softly closed one.
    public void Resume(DateTimeOffset? date)
    {
        open = true;
        observedState = tools.Count == 0 && !unnamedTool ? TokenActivityState.Working : TokenActivityState.Tool;
        Touch(date);
    }

    public void AddTool(string id, string? name)
    {
        unnamedTool = false;
        tools.RemoveAll(tool => tool.Id == id);
        tools.Add((id, name));
        if (tools.Count > 256) tools.RemoveRange(0, tools.Count - 256);
    }

    public void RemoveTool(string id) => tools.RemoveAll(tool => tool.Id == id);

    public void ClearTools()
    {
        tools.Clear();
        unnamedTool = false;
    }

    public void AwaitUnnamedTool(DateTimeOffset? date)
    {
        tools.Clear();
        unnamedTool = true;
        Resume(date);
    }

    public void Close(TokenActivityState state, DateTimeOffset? date)
    {
        if (state == TokenActivityState.Complete && open && startSeen && turnHasOutput && (date ?? LastActivity) is { } finished)
            Completion = new TokenTurnCompletion(output, null, finished, Model);
        open = false;
        tools.Clear();
        unnamedTool = false;
        observedState = state;
        Touch(date);
    }

    public void Compacted(DateTimeOffset? date)
    {
        if (date is { } at && (compactedAt is not { } last || at > last)) compactedAt = at;
    }

    public void Context(int? used, int? window, DateTimeOffset? date)
    {
        if (used is not ( > 0) || date is not { } at || (contextUsage is { } current && at < current.RecordedAt)) return;
        contextUsage = new TokenContextUsage(used.Value, window is > 0 ? window : null, at, null);
    }

    /// `tokens` is the message's whole output; only the growth since it was last seen counts.
    public void Output(string id, int tokens, DateTimeOffset? date)
    {
        var prior = counted.GetValueOrDefault(id);
        if (tokens <= prior) return;
        if (counted.Count >= 4_096) counted.Clear();
        counted[id] = tokens;
        var delta = tokens - prior;
        if (startSeen)
        {
            output = LogFields.Add(output, delta);
            turnHasOutput = true;
        }
        lastOutputDelta = delta;
        lastOutputAt = date;
        if (date is not { } at) return;
        Touch(at);
        recentOutputs.Add(new TokenOutputEvent(at, delta));
        if (recentOutputs.Count > 512) recentOutputs.RemoveRange(0, recentOutputs.Count - 512);
    }

    bool WaitsForInput => open && tools.Any(tool => InputTools.Contains(tool.Name ?? ""));
    DateTimeOffset? LiveAt => LastLogAt > LastActivity || LastActivity is null ? LastLogAt : LastActivity;

    /// The tracker's horizons: 600 s for the model, 900 s while a tool may run (shell commands, approvals), 24 h for a question.
    double LiveHorizon => WaitsForInput ? 86_400 : tools.Count == 0 && !unnamedTool ? 600 : 900;

    public bool IsActive(DateTimeOffset now) =>
        open && LiveAt is { } live && (now - live).TotalSeconds is var age && age >= -5 && age <= LiveHorizon;

    public bool IsRecent(DateTimeOffset now) => open || (LiveAt is { } live && (now - live).TotalSeconds <= 3_600);

    public TokenActivityState ActivityState(DateTimeOffset now)
    {
        if (!open) return observedState;
        if (WaitsForInput) return IsActive(now) ? TokenActivityState.Input : TokenActivityState.Unfinished;
        if (IsActive(now)) return observedState;
        return LiveAt is { } live && (now - live).TotalSeconds <= 1_800 ? TokenActivityState.Stale : TokenActivityState.Unfinished;
    }

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        if (LastActivity is null) return [];
        (string Id, string? Name)? tool = null;
        if (open && (unnamedTool || tools.Count > 0))
        {
            tool = tools.LastOrDefault(item => InputTools.Contains(item.Name ?? ""));
            if (tool?.Id is null) tool = tools.Count > 0 ? tools[^1] : null;
        }
        return [new TokenReading(Source, id)
        {
            SessionID = SessionID,
            ParentSessionID = ParentSessionID,
            AgentID = AgentID,
            AgentRole = AgentRole,
            IsSubagent = IsSubagent,
            Project = Project,
            ProjectPath = ProjectPath,
            Model = Model ?? Completion?.Model,
            ToolName = tool?.Name,
            ToolCategory = open && (unnamedTool || tools.Count > 0) ? tool?.Name is { } name ? Category(name) : TokenCat.ToolCategory.Other : null,
            Context = contextUsage is { } usage ? usage with { CompactedAt = compactedAt } : null,
            LastActivity = LastActivity,
            LastLogAt = LastLogAt,
            MeasurementAt = Completion?.FinishedAt ?? LastActivity,
            Active = IsActive(now),
            ActivityState = ActivityState(now),
            CurrentTurnStartedAt = open ? startedAt : null,
            CurrentTurnOutputTokens = open && startSeen ? output : null,
            LastOutputAt = lastOutputAt,
            LastOutputDelta = lastOutputDelta,
            RecentOutputs = [.. recentOutputs.Where(e => (now - e.At).TotalSeconds is >= -5 and <= TokenTracker.RecentOutputWindow)],
            LastOutputTokens = Completion?.Output,
            SampledAt = now,
        }];
    }

    /// Gemini CLI and Qwen Code tool names; anything else falls back to the shared table.
    public static ToolCategory Category(string name) => name switch
    {
        "run_shell_command" or "monitor" => TokenCat.ToolCategory.Command,
        "read_file" or "write_file" or "edit" or "replace" or "glob" or "grep_search" or "search_file_content" or "list_directory"
            or "read_many_files" or "notebook_edit" => TokenCat.ToolCategory.File,
        "google_web_search" => TokenCat.ToolCategory.Web,
        "agent" or "invoke_agent" or "delegate_to_agent" or "task_stop" or "create_sub_session" => TokenCat.ToolCategory.Agent,
        "read_mcp_resource" => TokenCat.ToolCategory.Mcp,
        "ask_user_question" or "ask_user" or "exit_plan_mode" => TokenCat.ToolCategory.Question,
        _ => TokenLogParser.Category(name),
    };

    public static int? Integer(JsonElement? value) =>
        value?.Number is { } number && number >= 0 && number <= int.MaxValue && Math.Truncate(number) == number ? (int)number : null;

    /// ISO 8601 as the clients write it (`toISOString()`), with an optional fraction and Z or an offset.
    public static DateTimeOffset? Date(JsonElement? value) =>
        value?.Text is { } text && DateTimeOffset.TryParseExact(text, ["yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK", "yyyy-MM-dd'T'HH:mm:ssK"],
            CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed)
        && parsed.Year is > 1 and < 9999 ? parsed : null;
}

/// New complete lines of an append-only JSONL log: a bounded first read, line reassembly, a 1 MB line cap, and a restart
/// when the file is replaced or truncated.
file sealed class ChatLineTail(string path)
{
    long offset;
    long identity;
    bool initialized;
    MemoryStream pending = new();
    bool dropping;
    const int MaximumLineBytes = 1_048_576;
    const FileShare Sharing = FileShare.ReadWrite | FileShare.Delete; // never block the writer's appends or renames

    /// `restart` runs before a replaced or truncated log is read again; `header` gets the first line when the first read
    /// starts past it (session metadata only).
    public void Read(int tailLimit, Action restart, Action<ReadOnlySpan<byte>> header, Action<ReadOnlySpan<byte>> line)
    {
        var info = new FileInfo(path);
        if (!info.Exists) return;
        var size = info.Length;
        var currentIdentity = info.CreationTimeUtc.Ticks;
        if (initialized && (identity != currentIdentity || size < offset))
        {
            offset = 0;
            initialized = false;
            pending = new();
            dropping = false;
            restart();
        }
        if (initialized && size == offset) return;
        try
        {
            using var handle = new FileStream(path, FileMode.Open, FileAccess.Read, Sharing, bufferSize: 0);
            if (!initialized)
            {
                if (size > tailLimit)
                {
                    var head = ReadAt(handle, 0, 65_536);
                    if (head.AsSpan().IndexOf((byte)10) is var newline and >= 0) header(head.AsSpan(0, newline));
                }
                offset = size > tailLimit ? size - tailLimit : 0;
                dropping = offset > 0;
                identity = currentIdentity;
                initialized = true;
            }
            long budget = 16_777_216 + tailLimit;
            while (offset < size && budget > 0)
            {
                var data = ReadAt(handle, offset, (int)Math.Min(1_048_576, size - offset));
                if (data.Length == 0) break;
                offset += data.Length;
                budget -= data.Length;
                Split(data, line);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    static byte[] ReadAt(FileStream handle, long position, int count)
    {
        var buffer = new byte[count];
        handle.Position = position;
        var read = handle.ReadAtLeast(buffer, count, throwOnEndOfStream: false);
        return read == count ? buffer : buffer[..read];
    }

    void Split(byte[] data, Action<ReadOnlySpan<byte>> line)
    {
        var start = 0;
        while (start < data.Length)
        {
            var found = data.AsSpan(start).IndexOf((byte)10);
            var end = found < 0 ? data.Length : start + found;
            if (!dropping)
            {
                if (pending.Length + end - start <= MaximumLineBytes) pending.Write(data, start, end - start);
                else
                {
                    pending = new();
                    dropping = true;
                }
            }
            if (found < 0) break;
            if (!dropping && pending.Length > 0) line(pending.GetBuffer().AsSpan(0, (int)pending.Length));
            // One long line must not pin up to 1 MB per reader for good.
            if (pending.Length > 65_536) pending = new();
            else pending.SetLength(0);
            dropping = false;
            start = end + 1;
        }
    }
}

/// One Gemini CLI chat: a JSONL log, or a legacy JSON snapshot rewritten in place.
file sealed class GeminiChatReader : ITokenLogReader
{
    readonly string path;
    readonly bool legacy;
    readonly ChatLineTail tail;
    ChatTurnState state = new(TokenSource.Gemini);
    (long Modified, long Size)? snapshot;
    readonly HashSet<string> seen = new(StringComparer.Ordinal);
    string? lastMessageID;
    readonly string? subagentParent;
    /// From `.project_root`; the metadata's directories are used only without it.
    readonly string? projectRoot;
    readonly string? folderProject;

    public GeminiChatReader(string path)
    {
        this.path = path;
        legacy = Path.GetExtension(path) == ".json";
        tail = new ChatLineTail(path);
        var folder = Path.GetDirectoryName(path) ?? "";
        var parent = Path.GetFileName(folder);
        var chats = parent == "chats" ? folder : Path.GetDirectoryName(folder) ?? "";
        subagentParent = parent == "chats" ? null : parent;
        var projectFolder = Path.GetDirectoryName(chats) ?? "";
        projectRoot = ProjectRoot(projectFolder);
        // Older builds named the folder by a sha256 of the path, which is no name to show.
        var name = Path.GetFileName(projectFolder);
        folderProject = name.Length == 64 && name.All(char.IsAsciiHexDigit) ? null : name;
        Reset();
    }

    static string? ProjectRoot(string folder)
    {
        try
        {
            var file = new FileInfo(Path.Combine(folder, ".project_root"));
            if (file is not { Exists: true, Length: <= 4_096 }) return null;
            var text = File.ReadAllText(file.FullName).Trim();
            return Path.IsPathFullyQualified(text) || text.StartsWith('/') ? text : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    void Reset()
    {
        state = new ChatTurnState(TokenSource.Gemini);
        seen.Clear();
        lastMessageID = null;
        if (subagentParent is not null)
        {
            state.IsSubagent = true;
            state.ParentSessionID = subagentParent;
            state.SessionID = subagentParent;
        }
        if (projectRoot is not null) state.SetProject(projectRoot);
        else state.Project = folderProject;
    }

    /// A resumed legacy snapshot was migrated whole into `<name>.jsonl`, whose reader now counts it; the retained snapshot
    /// reader would list the same session twice.
    bool Migrated => legacy && File.Exists(path + "l");

    public bool IsRecent(DateTimeOffset now) => !Migrated && state.IsRecent(now);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now) => Migrated ? [] : state.Readings(id, now);

    public void Read(int tailLimit, DateTimeOffset now)
    {
        state.Clamp(now.AddSeconds(5));
        if (legacy)
        {
            ReadSnapshot();
            return;
        }
        tail.Read(tailLimit, Reset,
            line => { if (TokenLogParser.Record(line) is { } record) Metadata(record); },
            line => { if (TokenLogParser.Record(line) is { } record) Consume(record); });
    }

    /// Legacy snapshots are rewritten whole: reread (up to 32 MB) when the size or modification time changes.
    void ReadSnapshot()
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) return;
            var current = (info.LastWriteTimeUtc.Ticks, info.Length);
            if (snapshot == current || current.Length > 33_554_432) return;
            snapshot = current;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var data = new byte[stream.Length];
            stream.ReadExactly(data);
            if (TokenLogParser.Record(data) is not { } record) return;
            Reset();
            Metadata(record);
            if (record.Field("messages") is { ValueKind: JsonValueKind.Array } messages)
                foreach (var message in messages.EnumerateArray()) Message(message);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    void Consume(JsonElement record)
    {
        if (record.Field("$set") is { ValueKind: JsonValueKind.Object } update)
        {
            Metadata(update);
            if (update.Field("messages") is { ValueKind: JsonValueKind.Array } messages)
                foreach (var message in messages.EnumerateArray()) Message(message);
        }
        // A cancelled or failed request rolls the open turn back; otherwise the person rewound and waits to type.
        else if (record.Field("$rewindTo")?.Text is not null) state.Close(state.IsOpen ? TokenActivityState.Interrupted : TokenActivityState.Idle, null);
        else if (record.Field("$patch") is { ValueKind: JsonValueKind.Object } patch)
        {
            // A rollback that is no pure tail removes the turn's own prompt. Compression also removes messages, but
            // reorders the history (`orderIds`) around its summary, and the turn goes on.
            if (state.IsOpen && patch.Field("orderIds") is null && state.TurnMessageID is { } start
                && patch.Field("removeIds") is { ValueKind: JsonValueKind.Array } removed && removed.EnumerateArray().Any(item => item.Text == start))
                state.Close(TokenActivityState.Interrupted, null);
        }
        else if (record.Field("id")?.Text is not null && record.Field("type")?.Text is not null) Message(record);
        else if (record.Field("sessionId")?.Text is not null) Metadata(record);
    }

    void Metadata(JsonElement record)
    {
        if (record.Field("sessionId")?.Text is { Length: > 0 } id)
        {
            if (state.IsSubagent) state.AgentID = id;
            else state.SessionID = id;
        }
        if (record.Field("kind")?.Text == "subagent" && !state.IsSubagent)
        {
            state.IsSubagent = true;
            state.AgentID = state.SessionID;
        }
        state.Note(ChatTurnState.Date(record.Field("lastUpdated")));
        if (projectRoot is null && record.Field("directories") is { ValueKind: JsonValueKind.Array } directories
            && directories.GetArrayLength() > 0 && directories[0].Text is { } directory) state.SetProject(directory);
    }

    /// `deriveStableId(["environment-context"])`: the session-context turn every start, `/clear` and new chat records.
    static readonly string EnvironmentContextID =
        Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData("environment-context"u8))[..32];

    void Message(JsonElement record)
    {
        if (record.Field("id")?.Text is not { } id || record.Field("type")?.Text is not { } type) return;
        var date = ChatTurnState.Date(record.Field("timestamp"));
        var isNew = !seen.Contains(id);
        if (isNew)
        {
            if (seen.Count >= 8_192) seen.Clear();
            seen.Add(id);
            lastMessageID = id;
        }
        var isLatest = id == lastMessageID;
        var continuing = state.Continues(date);
        state.Note(date);
        switch (type)
        {
            case "user":
                if (!isNew || id == EnvironmentContextID) return;
                // Newer builds record tool results as user messages made only of functionResponse parts.
                var responses = record.Field("content") is { ValueKind: JsonValueKind.Array } parts
                    ? parts.EnumerateArray().Select(part => part.Field("functionResponse")).Where(response => response?.ValueKind == JsonValueKind.Object).ToList()
                    : [];
                if (responses.Count > 0)
                {
                    foreach (var response in responses)
                        if (response?.Field("id")?.Text is { } call) state.RemoveTool(call);
                    state.Resume(date);
                }
                // Input inside a live turn is the client's own: "Please continue." or a compression summary.
                else if (continuing) state.Resume(date);
                else state.Begin(date, id);
                break;
            case "gemini":
                // Replies are recorded with text content; a part list is a turn the client synced from its own history
                // (a compression acknowledgement, a placeholder for an interrupted reply) and carries no turn change.
                if (record.Field("content") is { ValueKind: JsonValueKind.Array }) return;
                if (record.Field("model")?.Text is { Length: > 0 } model) state.Model = model;
                if (record.Field("tokens") is { ValueKind: JsonValueKind.Object } tokens)
                {
                    var input = ChatTurnState.Integer(tokens.Field("input"));
                    state.Output(id, GeminiTokens.Output(ChatTurnState.Integer(tokens.Field("output")),
                        ChatTurnState.Integer(tokens.Field("thoughts")), input, ChatTurnState.Integer(tokens.Field("total"))), date);
                    state.Context(input, null, date);
                }
                var calls = record.Field("toolCalls") is { ValueKind: JsonValueKind.Array } list
                    ? list.EnumerateArray().Where(call => call.ValueKind == JsonValueKind.Object).ToList() : [];
                var finished = calls.Select(call => ChatTurnState.Date(call.Field("timestamp"))).Max();
                // An earlier message appended again (late tokens) does not move the turn.
                if (!isLatest)
                {
                    state.Touch(finished ?? date);
                    return;
                }
                if (calls.Count > 0)
                {
                    state.ClearTools();
                    foreach (var call in calls)
                        if (call.Field("status")?.Text is not ("success" or "error" or "cancelled"))
                            state.AddTool(call.Field("id")?.Text ?? Guid.NewGuid().ToString(), call.Field("name")?.Text);
                    if (!state.HasTools && calls.All(call => call.Field("status")?.Text == "cancelled"))
                        state.Close(TokenActivityState.Interrupted, finished ?? date);
                    else state.Resume(finished ?? date); // finished tools go back to the model next
                }
                // A reply without text is a tool request; its calls are written when they finish.
                else if (record.Field("content")?.Text == "") state.AwaitUnnamedTool(date);
                else state.Close(TokenActivityState.Complete, date);
                break;
            case "error":
                if (isNew) state.Close(TokenActivityState.Interrupted, date);
                break;
        }
    }
}

/// One Qwen Code chat or background subagent transcript.
file sealed class QwenChatReader : ITokenLogReader
{
    readonly string path;
    readonly ChatLineTail tail;
    ChatTurnState state = new(TokenSource.Qwen);
    readonly HashSet<string> seen = new(StringComparer.Ordinal);
    readonly (string Session, string Agent)? subagent;
    bool sidecarRead;

    public QwenChatReader(string path)
    {
        this.path = path;
        tail = new ChatLineTail(path);
        var name = Path.GetFileNameWithoutExtension(path);
        var folder = Path.GetDirectoryName(path) ?? "";
        subagent = Path.GetFileName(Path.GetDirectoryName(folder)) == "subagents" && name.StartsWith("agent-", StringComparison.Ordinal)
            ? (Path.GetFileName(folder), name[6..]) : null;
        Reset();
    }

    void Reset()
    {
        state = new ChatTurnState(TokenSource.Qwen);
        seen.Clear();
        sidecarRead = false;
        if (subagent is { } agent)
        {
            state.IsSubagent = true;
            state.SessionID = agent.Session;
            state.ParentSessionID = agent.Session;
            state.AgentID = agent.Agent;
        }
    }

    public bool IsRecent(DateTimeOffset now) => state.IsRecent(now);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now) => state.Readings(id, now);

    public void Read(int tailLimit, DateTimeOffset now)
    {
        state.Clamp(now.AddSeconds(5));
        ReadSidecar();
        tail.Read(tailLimit, Reset, _ => { }, line => { if (TokenLogParser.Record(line) is { } record) Consume(record); });
    }

    /// The subagent type from `agent-<id>.meta.json`, retried until present; its other keys are never kept.
    void ReadSidecar()
    {
        if (subagent is null || sidecarRead || state.AgentRole is not null) return;
        var sidecar = Path.ChangeExtension(path, ".meta.json");
        try
        {
            if (new FileInfo(sidecar) is not { Exists: true, Length: <= 65_536 }) return;
            using var stream = new FileStream(sidecar, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var data = new byte[stream.Length];
            stream.ReadExactly(data);
            if (TokenLogParser.Record(data) is not { } record) return;
            sidecarRead = true;
            state.AgentRole = TokenLogParser.Label(record.Field("agentType")) ?? state.AgentRole;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    void Consume(JsonElement record)
    {
        state.SetProject(record.Field("cwd")?.Text);
        // /branch copies the parent's records into the new session; they were counted there.
        if (record.Field("forkedFrom") is not null) return;
        if (record.Field("uuid")?.Text is { } uuid)
        {
            if (seen.Contains(uuid)) return;
            if (seen.Count >= 8_192) seen.Clear();
            seen.Add(uuid);
        }
        if (record.Field("sessionId")?.Text is { Length: > 0 } session)
        {
            state.SessionID = session;
            if (subagent is not null) state.ParentSessionID = session;
        }
        if (subagent is not null && state.AgentRole is null) state.AgentRole = TokenLogParser.Label(record.Field("agentName"));
        var date = ChatTurnState.Date(record.Field("timestamp"));
        state.Note(date);
        var subtype = record.Field("subtype")?.Text;
        var parts = record.Field("message")?.Field("parts") is { ValueKind: JsonValueKind.Array } array
            ? array.EnumerateArray().Where(part => part.ValueKind == JsonValueKind.Object).ToList() : [];
        switch (record.Field("type")?.Text)
        {
            case "user":
                if (subtype is null or "cron" || (subtype == "notification" && record.Field("deliveredTurn")?.Bool == true)) state.Begin(date);
                else if (subtype == "mid_turn_user_message") state.Resume(date);
                break;
            case "assistant":
                if (record.Field("model")?.Text is { Length: > 0 } model) state.Model = model;
                if (record.Field("usageMetadata") is { ValueKind: JsonValueKind.Object } usage)
                {
                    var prompt = ChatTurnState.Integer(usage.Field("promptTokenCount"));
                    state.Output(record.Field("uuid")?.Text ?? Guid.NewGuid().ToString(), GeminiTokens.Output(
                        ChatTurnState.Integer(usage.Field("candidatesTokenCount")), ChatTurnState.Integer(usage.Field("thoughtsTokenCount")),
                        prompt, ChatTurnState.Integer(usage.Field("totalTokenCount"))), date);
                    state.Context(prompt, ChatTurnState.Integer(record.Field("contextWindowSize")), date);
                }
                var calls = parts.Select(part => part.Field("functionCall")).Where(call => call?.ValueKind == JsonValueKind.Object).ToList();
                for (var index = 0; index < calls.Count; index++)
                    state.AddTool(calls[index]?.Field("id")?.Text ?? $"{record.Field("uuid")?.Text}#{index}", calls[index]?.Field("name")?.Text);
                if (calls.Count > 0 || state.HasTools) state.Resume(date);
                else if (parts.Any(part => part.Field("text")?.Text is not null && part.Field("thought")?.Bool != true))
                    state.Close(TokenActivityState.Complete, date);
                else state.Resume(date); // thoughts or usage alone: the model is still on this turn
                break;
            case "tool_result":
                if (record.Field("toolCallResult")?.Field("callId")?.Text is { } callId) state.RemoveTool(callId);
                foreach (var part in parts)
                    if (part.Field("functionResponse")?.Field("id")?.Text is { } call) state.RemoveTool(call);
                state.Resume(date);
                break;
            case "system":
                switch (subtype)
                {
                    case "turn_result":
                        switch (record.Field("systemPayload")?.Field("state")?.Text)
                        {
                            case "completed": state.Close(TokenActivityState.Complete, date); break;
                            case "cancelled" or "error": state.Close(TokenActivityState.Interrupted, date); break;
                        }
                        break;
                    case "rewind": state.Close(TokenActivityState.Idle, date); break;
                    case "chat_compression": state.Compacted(date); break;
                }
                break;
        }
    }
}
