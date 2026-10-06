using System.Text;
using System.Text.Json;

namespace TokenCat;

/// ClineLog.swift: Cline, Roo Code and Kilo Code tasks in a VS Code family editor (`globalStorage\<extension>\tasks\<task>\ui_messages.json`)
/// and Cline CLI sessions (`~\.cline\data\sessions\<id>\<id>.messages.json` beside its `<id>.json` manifest). Both are JSON
/// snapshots rewritten in place: a changed write time or size rereads the file. Only ask/say kinds, token counts, times, model
/// ids and the working directory survive; message text is never kept. No title is read: the task history's `task` and the
/// CLI manifest's `metadata.title` are the first prompt (or its opening), not a generated name.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Cline = new(ClineFiles, ClineLogReader.IsLog, path => new ClineLogReader(path));

    static List<string> ClineFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var found = new List<FileSystemInfo>();
        foreach (var root in roots)
        {
            var extensionTasks = Path.GetFileName(Path.TrimEndingDirectorySeparator(root)) == "tasks";
            foreach (var folder in TokenDiscovery.Children(root))
            {
                if (folder is not DirectoryInfo) continue;
                var file = new FileInfo(Path.Combine(folder.FullName, extensionTasks ? "ui_messages.json" : folder.Name + ".messages.json"));
                if (file.Exists) found.Add(file);
            }
        }
        return discovery.Recent(found);
    }
}

/// One task or CLI session. The whole snapshot is summarised on every change; nothing but the summary is kept.
sealed class ClineLogReader(string path) : ITokenLogReader
{
    const FileShare Sharing = FileShare.ReadWrite | FileShare.Delete; // never block the extension's rewrites
    const long MaximumBytes = 67_108_864;
    readonly bool cli = Path.GetFileName(path) != "ui_messages.json";
    /// Roo Code and Kilo Code, by the extension folder the task lives in; null for Cline.
    readonly string? clientName = path.Replace('\\', '/') is var normalized && normalized.Contains("/rooveterinaryinc.roo-cline/", StringComparison.OrdinalIgnoreCase)
        ? "Roo Code" : normalized.Contains("/kilocode.kilo-code/", StringComparison.OrdinalIgnoreCase) ? "Kilo Code" : null;
    (long Ticks, long Size)? stamp, manifestStamp, historyStamp, metadataStamp;
    DateTimeOffset? parsedAt;
    ClineLogSummary? summary;
    string? cwd;
    /// The first request was read without a working directory in it: it is never searched again.
    bool cwdSearched;
    /// Extension tasks: the newest model named in the conversation's environment details (Roo Code, Kilo Code).
    string? historyModel;
    string? metadataModel;

    /// A task's `ui_messages.json` or a CLI session's `<folder>.messages.json`; Windows paths are matched with `/`.
    public static bool IsLog(string path)
    {
        var normalized = path.Replace('\\', '/');
        var slash = normalized.LastIndexOf('/');
        var name = normalized[(slash + 1)..];
        var folder = slash > 0 ? normalized[(normalized.LastIndexOf('/', slash - 1) + 1)..slash] : "";
        return name == "ui_messages.json" || name == folder + ".messages.json";
    }

    public void Read(int tailLimit, DateTimeOffset now)
    {
        var folder = Path.GetDirectoryName(path) ?? "";
        if (cli)
        {
            var manifestPath = Path.Combine(folder, Path.GetFileName(folder) + ".json");
            var current = Stamp(path);
            var currentManifest = Stamp(manifestPath);
            if (current is null || (current == stamp && currentManifest == manifestStamp)) return;
            stamp = current;
            manifestStamp = currentManifest;
            using var messages = Document(path, MaximumBytes);
            if (messages is null || MessageArray(messages.RootElement) is not { } list) return;
            using var manifest = Document(manifestPath, 1_048_576);
            var manifestRoot = manifest?.RootElement;
            cwd = PathText(manifestRoot?.Field("cwd")) ?? cwd;
            summary = ClineLogSummary.FromCli(list, manifestRoot);
            return;
        }
        var currentStamp = Stamp(path);
        if (currentStamp is null || currentStamp == stamp) return;
        // A large task rewritten while it streams is summarised at most every 5 s.
        if (currentStamp.Value.Item2 > 8_388_608 && parsedAt is { } parsed && (now - parsed).TotalSeconds < 5) return;
        stamp = currentStamp;
        parsedAt = now;
        using (var document = Document(path, MaximumBytes))
        {
            if (document is null || MessageArray(document.RootElement) is not { } messages) return;
            summary = ClineLogSummary.FromTask(messages);
        }
        if (summary.Model is null) ReadTaskMetadata(folder);
        if ((cwd is null && !cwdSearched) || (summary.Model is null && metadataModel is null)) ReadHistory(folder);
    }

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        if (summary is not { LastAt: { } last } s) return [];
        var tool = s.Open ? s.Tool : null;
        return [new TokenReading(TokenSource.Cline, id)
        {
            ClientName = clientName,
            SessionID = Path.GetFileName(Path.GetDirectoryName(path)),
            Project = cwd is null ? null : LastComponent(cwd),
            ProjectPath = cwd,
            Model = s.Model ?? metadataModel ?? historyModel,
            LastActivity = last,
            LastLogAt = last,
            MeasurementAt = s.Completion?.At ?? last,
            Active = s.IsActive(now),
            ActivityState = s.State(now),
            ToolName = tool?.Name,
            ToolCategory = tool?.Category,
            CurrentTurnStartedAt = s.Open ? s.TurnStartedAt : null,
            CurrentTurnOutputTokens = s.Open ? s.TurnOutput : null,
            LastOutputAt = s.Events.Count > 0 ? s.Events[^1].At : null,
            LastOutputDelta = s.Events.Count > 0 ? s.Events[^1].Tokens : null,
            RecentOutputs = [.. s.Events.Where(e => (now - e.At).TotalSeconds is >= -5 and <= TokenTracker.RecentOutputWindow)],
            LastOutputTokens = s.Completion?.Output,
            SampledAt = now,
        }];
    }

    public bool IsRecent(DateTimeOffset now) => summary is { } s && (s.Open || s.LastAt is { } last && (now - last).TotalSeconds <= 3_600);

    /// Cline's older tasks name the model only in `task_metadata.json` (`model_usage[].model_id`).
    void ReadTaskMetadata(string folder)
    {
        var metadataPath = Path.Combine(folder, "task_metadata.json");
        var current = Stamp(metadataPath);
        if (current is null || current == metadataStamp) return;
        metadataStamp = current;
        using var document = Document(metadataPath, 4_194_304);
        var usage = LogFields.Objects(document?.RootElement.Field("model_usage"));
        metadataModel = usage.AsEnumerable().Reverse().Select(entry => ClineLogSummary.ModelName(entry.Field("model_id"))).FirstOrDefault(m => m is not null)
            ?? metadataModel;
    }

    /// The working directory from the first request's environment details (Cline "Current Working Directory (…) Files",
    /// Roo Code and Kilo Code "Current Workspace Directory (…) Files"), and Roo Code's `<model>…</model>` from the newest one.
    /// The head is read in 1 MB steps (pasted images and attached files come first) until the marker, the first reply or
    /// 8 MB; the tail is bounded. Only the text between the markers is decoded.
    void ReadHistory(string folder)
    {
        var historyPath = Path.Combine(folder, "api_conversation_history.json");
        var current = Stamp(historyPath);
        if (current is null || current == historyStamp) return;
        historyStamp = current;
        try
        {
            using var handle = new FileStream(historyPath, FileMode.Open, FileAccess.Read, Sharing, bufferSize: 0);
            if (cwd is null && !cwdSearched)
            {
                var head = new MemoryStream();
                while (head.Length < 8_388_608 && ReadAt(handle, head.Length, (int)Math.Min(1_048_576, handle.Length - head.Length)) is { Length: > 0 } chunk)
                {
                    head.Write(chunk);
                    var bytes = head.ToArray();
                    cwd = PathText(Between(bytes, ["Current Working Directory (", "Current Workspace Directory ("], ") Files", last: false));
                    if (cwd is not null) break;
                    if (bytes.AsSpan().IndexOf("\"role\":\"assistant\""u8) >= 0 || head.Length >= 8_388_608)
                    {
                        cwdSearched = true;
                        break;
                    }
                }
            }
            if (summary?.Model is not null || metadataModel is not null) return;
            var start = Math.Max(0, handle.Length - 131_072);
            historyModel = ClineLogSummary.ModelName(Between(ReadAt(handle, start, (int)(handle.Length - start)), ["<model>"], "</model>", last: true))
                ?? historyModel;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// The JSON-escaped text between a start marker and `end`, decoded; the first match, or the last one.
    static string? Between(byte[] data, string[] starts, string end, bool last)
    {
        var text = Encoding.UTF8.GetString(data);
        var found = starts.Select(marker => (Marker: marker, Index: last ? text.LastIndexOf(marker, StringComparison.Ordinal) : text.IndexOf(marker, StringComparison.Ordinal)))
            .Where(match => match.Index >= 0).ToList();
        if (found.Count == 0) return null;
        var (marker, index) = last ? found.MaxBy(match => match.Index) : found.MinBy(match => match.Index);
        var from = index + marker.Length;
        var close = text.IndexOf(end, from, StringComparison.Ordinal);
        if (close < 0 || close - from > 4_096) return null;
        try { return JsonSerializer.Deserialize<string>("\"" + text[from..close] + "\""); }
        catch (JsonException) { return null; }
    }

    static string? PathText(JsonElement? value) => PathText(value?.Text);
    static string? PathText(string? value) => value is { Length: > 0 and <= 4_096 } ? value : null;

    static string LastComponent(string path) => Path.GetFileName(Path.TrimEndingDirectorySeparator(path.Replace('\\', '/')).Replace('/', Path.DirectorySeparatorChar)) is { Length: > 0 } name ? name : path;

    /// The message array (the CLI may wrap it as `{messages: […]}`).
    static List<JsonElement>? MessageArray(JsonElement root) =>
        root.ValueKind == JsonValueKind.Array ? LogFields.Objects(root)
        : root.Field("messages") is { ValueKind: JsonValueKind.Array } messages ? LogFields.Objects(messages) : null;

    static (long, long)? Stamp(string file)
    {
        var info = new FileInfo(file);
        return info.Exists ? (info.LastWriteTimeUtc.Ticks, info.Length) : null;
    }

    static JsonDocument? Document(string file, long limit)
    {
        try
        {
            using var handle = new FileStream(file, FileMode.Open, FileAccess.Read, Sharing, bufferSize: 0);
            if (handle.Length > limit) return null;
            return JsonDocument.Parse(ReadAt(handle, 0, (int)handle.Length), Json.Depth);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    static byte[] ReadAt(FileStream handle, long position, int count)
    {
        var buffer = new byte[count];
        handle.Position = position;
        var read = handle.ReadAtLeast(buffer, count, throwOnEndOfStream: false);
        return read == count ? buffer : buffer[..read];
    }
}

/// Turn state and token counts of one task, derived from message kinds, `ts` (ms) and request counts only.
sealed class ClineLogSummary
{
    public string? Model { get; private set; }
    public DateTimeOffset? LastAt { get; private set; }
    public bool Open { get; private set; }
    public DateTimeOffset? TurnStartedAt { get; private set; }
    public int TurnOutput { get; private set; }
    public (int Output, DateTimeOffset At)? Completion { get; private set; }
    public List<TokenOutputEvent> Events { get; } = [];
    public (string Name, ToolCategory Category)? Tool { get; private set; }
    TokenActivityState waiting = TokenActivityState.Idle;

    /// Asks that end the turn: the task finished, or the model's plan-mode reply waits for the next prompt.
    static readonly HashSet<string> FinishingAsks = ["completion_result", "resume_completed_task", "plan_mode_respond"];
    /// Asks that hold an open turn until the person answers: questions, approvals, and failures that offer a retry.
    static readonly HashSet<string> InputAsks = ["followup", "command", "tool", "use_mcp_server", "browser_action_launch",
        "act_mode_respond", "new_task", "condense", "summarize_task", "report_bug", "use_subagents", "api_req_failed",
        "mistake_limit_reached", "auto_approval_max_req_reached"];
    /// Messages a person or a new request writes; only these reopen a finished task.
    static readonly HashSet<string> OpeningSays = ["task", "user_feedback", "user_feedback_diff", "api_req_started"];

    /// `ui_messages.json` of a Cline, Roo Code or Kilo Code task.
    public static ClineLogSummary FromTask(List<JsonElement> messages)
    {
        var s = new ClineLogSummary();
        // A finished request's output is placed at its last message, the closest logged time to its end.
        int? pending = null;
        DateTimeOffset? pendingAt = null;
        void Flush()
        {
            if (pending is { } tokens && pendingAt is { } at) s.Record(tokens, at);
            pending = null;
        }
        // Only the last message of an open turn decides its tool and state.
        (string? Say, string? Ask, bool Partial, string? Text)? last = null;
        for (var index = 0; index < messages.Count; index++)
        {
            var message = messages[index];
            if (LogFields.Milliseconds(message.Field("ts")) is not { } at) continue;
            s.LastAt = s.LastAt is { } previous && previous > at ? previous : at;
            if (ModelName(message.Field("modelInfo")?.Field("modelId")) is { } id) s.Model = id;
            var partial = message.Field("partial")?.Bool == true;
            var type = message.Field("type")?.Text;
            var say = type == "say" ? message.Field("say")?.Text : null;
            var ask = type == "ask" ? message.Field("ask")?.Text : null;
            JsonElement? request = null;
            using var requestDocument = say == "api_req_started" ? Parse(message.Field("text")?.Text) : null;
            if (say == "api_req_started")
            {
                Flush();
                request = requestDocument?.RootElement;
            }
            if (!s.Open && ((say is not null && OpeningSays.Contains(say)) || (index == 0 && say == "text")))
            {
                s.Open = true;
                s.TurnStartedAt = at;
                s.TurnOutput = 0;
                s.Tool = null;
            }
            if (request is { } info)
            {
                if (LogFields.Count(info.Field("tokensOut")) is { } tokens and > 0)
                {
                    s.TurnOutput = LogFields.Add(s.TurnOutput, tokens);
                    pending = tokens;
                }
                if (info.Field("cancelReason")?.ValueKind == JsonValueKind.String)
                {
                    s.Open = false;
                    s.waiting = TokenActivityState.Interrupted;
                }
            }
            pendingAt = at;
            if (!s.Open) continue;
            if (ask is not null && !partial)
            {
                // A Roo Code or Kilo Code subtask ends by asking to hand its result back to the parent (`finishTask`).
                if (FinishingAsks.Contains(ask)
                    || (ask == "tool" && message.Field("text")?.Text is { } text && text.Contains("finishTask", StringComparison.Ordinal)
                        && ToolName(text) == "finishTask"))
                {
                    s.Completion = (s.TurnOutput, at);
                    s.Open = false;
                    s.waiting = TokenActivityState.Complete;
                    last = null;
                    continue;
                }
                if (ask == "resume_task")
                {
                    s.Open = false;
                    s.waiting = TokenActivityState.Interrupted;
                    last = null;
                    continue;
                }
            }
            last = (say, ask, partial, message.Field("text")?.Text);
        }
        if (s.Open && last is { } final)
        {
            s.Tool = ToolOf(final.Say, final.Ask, final.Partial, final.Text);
            s.waiting = s.Tool?.Category == ToolCategory.Agent ? TokenActivityState.Tool : StateOf(final.Say, final.Ask, final.Partial);
        }
        Flush();
        return s;
    }

    /// `<id>.messages.json` of a Cline CLI session with its manifest: the manifest status says whether a turn runs.
    public static ClineLogSummary FromCli(List<JsonElement> messages, JsonElement? manifest)
    {
        var s = new ClineLogSummary();
        string? lastToolUse = null;
        foreach (var message in messages)
        {
            if (LogFields.Milliseconds(message.Field("ts")) is not { } at) continue;
            s.LastAt = s.LastAt is { } previous && previous > at ? previous : at;
            if (ModelName(message.Field("modelInfo")?.Field("id")) is { } id) s.Model = id;
            var content = message.Field("content");
            var blocks = LogFields.Objects(content);
            var types = blocks.Select(block => block.Field("type")?.Text).OfType<string>().ToList();
            var role = message.Field("role")?.Text;
            if (role == "user" && (content?.ValueKind == JsonValueKind.String || (types.Contains("text") && !types.Contains("tool_result"))))
            {
                s.TurnStartedAt = at;
                s.TurnOutput = 0;
                lastToolUse = null;
            }
            else if (role == "assistant")
            {
                if (LogFields.Count(message.Field("metrics")?.Field("outputTokens")) is { } tokens and > 0)
                {
                    s.TurnOutput = LogFields.Add(s.TurnOutput, tokens);
                    s.Record(tokens, at);
                }
                var call = blocks.LastOrDefault(block => block.Field("type")?.Text is "tool_use" or "tool_call" or "tool-call");
                lastToolUse = call.ValueKind == JsonValueKind.Object ? TokenLogParser.Label(call.Field("name")) ?? "tool" : null;
            }
            // A tool result answers the call; the model works again.
            else if (types.Count > 0 || role == "tool") lastToolUse = null;
        }
        s.Model ??= ModelName(manifest?.Field("model"));
        switch (manifest?.Field("status")?.Text)
        {
            case "running" or "starting" or "pending" or "stopping":
                s.Open = true;
                if (lastToolUse is { } name)
                {
                    s.Tool = (name, TokenLogParser.Category(name));
                    s.waiting = TokenActivityState.Tool;
                }
                else s.waiting = TokenActivityState.Working;
                break;
            case "cancelled" or "failed" or "error":
                s.waiting = TokenActivityState.Interrupted;
                break;
            default:
                s.waiting = TokenActivityState.Complete;
                if ((LogFields.Date(manifest?.Field("ended_at")) ?? s.LastAt) is { } finished && s.TurnStartedAt is not null)
                    s.Completion = (s.TurnOutput, finished);
                break;
        }
        return s;
    }

    void Record(int tokens, DateTimeOffset at)
    {
        Events.Add(new TokenOutputEvent(at, tokens));
        if (Events.Count > 512) Events.RemoveRange(0, Events.Count - 512);
    }

    /// How long an open turn may stay silent and still count as running; a question or approval waits for the person, and
    /// a Roo Code or Kilo Code parent waits for its subtask as long as that runs.
    double LiveHorizon => waiting switch
    {
        TokenActivityState.Input => 86_400,
        TokenActivityState.Tool => Tool?.Category == ToolCategory.Agent ? 3_600 : 900,
        _ => 600,
    };

    public bool IsActive(DateTimeOffset now) => Open && LastAt is { } last && (now - last).TotalSeconds is var age && age >= -5 && age <= LiveHorizon;

    public TokenActivityState State(DateTimeOffset now)
    {
        if (!Open || IsActive(now)) return waiting;
        if (waiting == TokenActivityState.Input) return TokenActivityState.Unfinished;
        return LastAt is { } last && (now - last).TotalSeconds <= 1_800 ? TokenActivityState.Stale : TokenActivityState.Unfinished;
    }

    static TokenActivityState StateOf(string? say, string? ask, bool partial)
    {
        if (partial) return TokenActivityState.Output;
        if (ask is not null)
            return InputAsks.Contains(ask) ? TokenActivityState.Input : ask == "command_output" ? TokenActivityState.Tool : TokenActivityState.Working;
        return say is "command" or "command_output" or "tool" or "browser_action" or "browser_action_launch" or "use_mcp_server"
            or "mcp_server_request_started" ? TokenActivityState.Tool : TokenActivityState.Working;
    }

    static (string Name, ToolCategory Category)? ToolOf(string? say, string? ask, bool partial, string? text)
    {
        // An approved `newTask` ask is the parent's last record while its subtask runs.
        if (ask == "tool" && !partial && ToolName(text) == "newTask") return ("newTask", ToolCategory.Agent);
        if (ask is not null && !partial && InputAsks.Contains(ask)) return (ask, ToolCategory.Question);
        switch (ask ?? say)
        {
            case "command" or "command_output": return ("command", ToolCategory.Command);
            case "browser_action" or "browser_action_launch": return ("browser", ToolCategory.Web);
            case "use_mcp_server" or "mcp_server_request_started": return ("mcp", ToolCategory.Mcp);
            case "tool":
                // The tool's own name ("readFile", "editedExistingFile"); its paths and content are not kept.
                var name = ToolName(text) ?? "tool";
                return (name, name.StartsWith("web", StringComparison.Ordinal) ? ToolCategory.Web
                    : new[] { "File", "file", "Diff", "Definition" }.Any(part => name.Contains(part, StringComparison.Ordinal)) ? ToolCategory.File
                    : ToolCategory.Other);
            default: return null;
        }
    }

    /// The `tool` field of a tool message's JSON text.
    static string? ToolName(string? text)
    {
        using var document = Parse(text);
        return TokenLogParser.Label(document?.RootElement.Field("tool"));
    }

    public static string? ModelName(JsonElement? value) => ModelName(value?.Text);

    public static string? ModelName(string? value) =>
        value?.Trim() is { Length: >= 1 and <= 128 } text && !text.Contains('\n') ? text : null;

    static JsonDocument? Parse(string? text)
    {
        if (text is null) return null;
        try { return JsonDocument.Parse(text, Json.Depth); }
        catch (JsonException) { return null; }
    }
}
