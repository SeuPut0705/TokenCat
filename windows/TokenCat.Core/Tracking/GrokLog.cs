using System.Text;
using System.Text.Json;

namespace TokenCat;

/// GrokLog.swift: Grok Build (xAI's `grok` CLI), one folder per session, `%GROK_HOME%\sessions\<encoded cwd>\<session id>\`
/// (default `%USERPROFILE%\.grok`). The cwd folder is the URL-encoded path, or a slug plus hash with the path in its `.cwd`
/// file. Turn state from `events.jsonl` (turn_started, tool_started/tool_completed by `tool_name`, permission_requested/
/// permission_resolved, turn_ended `outcome`); `updates.jsonl` (the tracked log) only for `turn_completed` usage (counted when
/// the unified log did not cover the turn) and `elapsed_ms`; `summary.json` for cwd, model, effort, context window, title
/// (`generated_title`, never the prompt's opening words a failed title request leaves) and `session_kind`/`parent_session_id`;
/// the parent's `subagents\<child id>\meta.json` for a subagent's parent and type; `%GROK_HOME%\logs\unified.jsonl`
/// `shell.turn.inference_done` lines (by `sid`) for each model call's output, context and measured duration.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Grok = new(GrokFiles,
        path => System.IO.Path.GetFileName(path) == "updates.jsonl" && !path.Replace('\\', '/').Contains("/subagents/", StringComparison.Ordinal),
        path => new GrokLogReader(path));

    static List<string> GrokFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var found = new List<FileSystemInfo>();
        foreach (var root in roots)
            foreach (var group in TokenDiscovery.Children(root).OfType<DirectoryInfo>())
                foreach (var session in TokenDiscovery.Children(group.FullName).OfType<DirectoryInfo>())
                    if (new FileInfo(System.IO.Path.Combine(session.FullName, "updates.jsonl")) is { Exists: true } log) found.Add(log);
        return discovery.Recent(found);
    }
}

public sealed class GrokLogReader : ITokenLogReader
{
    /// Tools that wait for the person rather than run.
    static readonly HashSet<string> InputTools = ["ask_user_question", "exit_plan_mode"];
    static readonly byte[] TurnCompletedMarker = Encoding.UTF8.GetBytes("\"turn_completed\"");
    static readonly byte[] UserChunkMarker = Encoding.UTF8.GetBytes("\"user_message_chunk\"");

    readonly string directory;
    readonly string sessionID;
    readonly GrokUnifiedLog unified;
    LogLineTail events;
    LogLineTail updates;
    int unifiedCursor;
    LogTurnState turn = new(InputTools);
    /// A `turn_started` or `turn_ended` was read, so later activity outside a turn is not a turn whose start was skipped.
    bool sawBoundary;
    readonly List<(string Id, string Name)> pendingTools = [];
    int toolSerial;
    /// The open turn got output from the unified log, so its `turn_completed` usage is not counted again.
    bool turnCallOutput;
    /// A `turn_completed` usage counted the turn ending here; unified calls up to it are not counted again.
    DateTimeOffset? accountedThrough;
    double? lastTurnSeconds;
    string? turnModel;
    TokenContextUsage? context;
    TokenSpeedMeasurement? measurement;

    (long, long, long)? summaryStamp;
    string? cwd;
    string? summaryModel;
    string? effort;
    string? title;
    /// The generated title last compared with the first prompt, and whether the comparison could be made.
    (string? Generated, bool Verified)? checkedTitle;
    int? windowTokens;
    bool isSubagent;
    string? parentSessionID;
    string? agentRole;
    bool metaFound;
    DateTimeOffset? parentSearchedAt;

    public GrokLogReader(string path)
    {
        directory = System.IO.Path.GetDirectoryName(path)!;
        sessionID = System.IO.Path.GetFileName(directory);
        events = new LogLineTail(System.IO.Path.Combine(directory, "events.jsonl"));
        updates = new LogLineTail(path);
        var sessions = System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(directory)!)!;
        unified = GrokUnifiedLog.Shared(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(sessions)!, "logs", "unified.jsonl"));
    }

    public bool IsRecent(DateTimeOffset now) => turn.IsRecent(now);

    string? Model => turn.TurnOpen ? turnModel ?? summaryModel : summaryModel ?? turnModel;

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        if (turn.Reading(TokenSource.Grok, id, Model, cwd, now) is not { } reading) return [];
        reading = reading with
        {
            SessionID = sessionID, Title = title, Effort = effort,
            ToolCategory = turn.RunningTool is { } tool ? tool.Name is { } name ? Category(name) : ToolCategory.Other : reading.ToolCategory,
            Context = context is { } usage ? usage with { WindowTokens = windowTokens } : null,
            SpeedMeasurement = measurement,
            LastTurnDurationSeconds = reading.LastOutputTokens is not null ? lastTurnSeconds : null,
        };
        if (isSubagent) reading = reading with { IsSubagent = true, ParentSessionID = parentSessionID, AgentID = sessionID, AgentRole = agentRole };
        return [reading];
    }

    public void Read(int tailLimit, DateTimeOffset now)
    {
        turn.Clamp(now.AddSeconds(5));
        ReadSummary();
        unified.Refresh(tailLimit);
        if (Collect(tailLimit) is { } steps) Apply(steps);
        else
        {
            Restart();
            if (Collect(tailLimit) is { } again) Apply(again);
        }
        FindParent(now);
    }

    /// A replaced or truncated events or updates file: both are read again from a bounded tail with fresh turn state.
    void Restart()
    {
        events = new LogLineTail(events.Path);
        updates = new LogLineTail(updates.Path);
        turn = new LogTurnState(InputTools);
        sawBoundary = false;
        pendingTools.Clear();
        unifiedCursor = 0;
        turnCallOutput = false;
        accountedThrough = null;
        lastTurnSeconds = null;
        context = null;
        measurement = null;
    }

    enum StepKind { TurnStarted, Activity, ToolStarted, ToolCompleted, PermissionRequested, PermissionResolved, TurnEnded, Other, Completed, Call }

    readonly record struct Step(DateTimeOffset At, StepKind Kind, string? Text = null, bool Flag = false, int? Output = null,
                                double? ElapsedMs = null, GrokUnifiedLog.Call? Call = null);

    /// The new steps of all three logs in time order (events, then updates, then calls on equal times); null when the
    /// events or updates file was replaced or truncated.
    List<Step>? Collect(int tailLimit)
    {
        var steps = new List<Step>();
        var replaced = false;
        events.Read(tailLimit, () => replaced = true, line =>
        {
            if (Event(line) is { } step) steps.Add(step);
        });
        updates.Read(tailLimit, () => replaced = true, line =>
        {
            if (line.AsSpan().IndexOf(TurnCompletedMarker) >= 0 && Completion(line) is { } step) steps.Add(step);
        });
        if (replaced) return null;
        foreach (var call in unified.Calls(sessionID, unifiedCursor))
        {
            steps.Add(new Step(call.At, StepKind.Call, Call: call));
            unifiedCursor = call.Serial;
        }
        return [.. steps.OrderBy(step => step.At)]; // stable, as the mac's offset tie-break
    }

    static Step? Event(byte[] line)
    {
        if (Json.Parse(line) is not { ValueKind: JsonValueKind.Object } record || record.Field("type")?.Text is not { } type
            || LogFields.Date(record.Field("ts")) is not { } at) return null;
        var tool = TokenLogParser.Label(record.Field("tool_name")) ?? "tool";
        return type switch
        {
            "turn_started" => new Step(at, StepKind.TurnStarted, ModelName(record.Field("model_id"))),
            "loop_started" or "first_token" or "phase_changed" or "interjected" => new Step(at, StepKind.Activity),
            "tool_started" => new Step(at, StepKind.ToolStarted, tool),
            "tool_completed" => new Step(at, StepKind.ToolCompleted, tool),
            "permission_requested" => new Step(at, StepKind.PermissionRequested, tool),
            "permission_resolved" => new Step(at, StepKind.PermissionResolved, tool),
            "turn_ended" => new Step(at, StepKind.TurnEnded, Flag: record.Field("outcome")?.Text == "completed"),
            _ => new Step(at, StepKind.Other),
        };
    }

    /// A `turn_completed` update: its usage output, turn duration and whether it ended normally. Text fields are dropped.
    static Step? Completion(byte[] line)
    {
        if (Json.Parse(line) is not { ValueKind: JsonValueKind.Object } record || record.Field("params") is not { } parameters
            || parameters.Field("update") is not { ValueKind: JsonValueKind.Object } update
            || update.Field("sessionUpdate")?.Text != "turn_completed") return null;
        var at = LogFields.Milliseconds(parameters.Field("_meta")?.Field("agentTimestampMs"))
            ?? (record.Field("timestamp")?.Number is { } seconds && seconds > 0 ? DateTimeOffset.UnixEpoch.AddTicks((long)(seconds * TimeSpan.TicksPerSecond)) : null);
        if (at is null) return null;
        var stop = update.Field("stop_reason")?.Text;
        return new Step(at.Value, StepKind.Completed, Flag: stop is not ("cancelled" or "error"),
            Output: LogFields.Count(update.Field("usage")?.Field("outputTokens")), ElapsedMs: GrokUnifiedLog.Milliseconds(update.Field("elapsed_ms")));
    }

    void Apply(List<Step> steps)
    {
        foreach (var step in steps)
        {
            var at = step.At;
            turn.Logged(at);
            switch (step.Kind)
            {
                case StepKind.TurnStarted:
                    sawBoundary = true;
                    turnModel = step.Text ?? turnModel;
                    pendingTools.Clear();
                    turnCallOutput = false;
                    turn.Begin(at, whole: unified.Covers(at));
                    break;
                case StepKind.Activity:
                    ResumeUnseenTurn(at);
                    if (turn.TurnOpen) turn.SetState(pendingTools.Count == 0 ? TokenActivityState.Working : TokenActivityState.Tool, at);
                    break;
                case StepKind.ToolStarted:
                    ResumeUnseenTurn(at);
                    if (!turn.TurnOpen) break;
                    toolSerial++;
                    var id = toolSerial.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    pendingTools.Add((id, step.Text!));
                    if (pendingTools.Count > 256) pendingTools.RemoveRange(0, pendingTools.Count - 256);
                    turn.StartTool(id, step.Text, at);
                    break;
                case StepKind.ToolCompleted:
                    // Parallel calls of one tool finish in any order; the oldest of that name is closed.
                    var index = pendingTools.FindIndex(tool => tool.Name == step.Text);
                    if (index >= 0)
                    {
                        var finished = pendingTools[index].Id;
                        pendingTools.RemoveAt(index);
                        turn.FinishTool(finished, at);
                    }
                    else turn.Touch(at);
                    break;
                case StepKind.PermissionRequested:
                    ResumeUnseenTurn(at);
                    turn.StartRequest("permission:" + step.Text, at);
                    break;
                case StepKind.PermissionResolved:
                    turn.FinishRequest("permission:" + step.Text);
                    turn.Touch(at);
                    break;
                case StepKind.TurnEnded:
                    sawBoundary = true;
                    pendingTools.Clear();
                    turn.Close(step.Flag ? TokenActivityState.Complete : TokenActivityState.Interrupted, at, Model);
                    break;
                case StepKind.Completed:
                    if (!step.Flag) break;
                    if (step.Output is > 0 and var output && !turnCallOutput)
                    {
                        turn.AddOutput(output, at);
                        accountedThrough = at;
                    }
                    if (step.ElapsedMs is { } elapsed) lastTurnSeconds = elapsed / 1_000;
                    break;
                case StepKind.Call when step.Call is { } call:
                    if (call.Prompt > 0) context = new TokenContextUsage(call.Prompt, null, at, null);
                    if (call.Output <= 0 || accountedThrough is { } accounted && at <= accounted) break;
                    turn.AddOutput(call.Output, at);
                    turnCallOutput = true;
                    if (call.ElapsedMs is { } duration)
                        measurement = new TokenSpeedMeasurement
                        {
                            Model = Model, At = at, OutputTokens = call.Output, RequestDurationMs = duration,
                            RequestDurationIncludesRetries = call.Retried, TtftMs = call.TtftMs,
                        };
                    break;
            }
        }
    }

    /// Activity while no turn is open opens one only when its `turn_started` lay before the events tail.
    void ResumeUnseenTurn(DateTimeOffset at)
    {
        if (!sawBoundary && events.SkippedHead) turn.Resume(at);
    }

    void ReadSummary()
    {
        try
        {
            var info = new FileInfo(System.IO.Path.Combine(directory, "summary.json"));
            if (!info.Exists)
            {
                cwd ??= GroupCwd(System.IO.Path.GetDirectoryName(directory)!);
                return;
            }
            var current = (info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks);
            if (current == summaryStamp) return;
            summaryStamp = current;
            if (info.Length > 1_048_576 || Json.Parse(ReadAll(info.FullName)) is not { ValueKind: JsonValueKind.Object } summary) return;
            if (LogFields.Text(summary.Field("info")?.Field("cwd")) is { Length: <= 4_096 } path) cwd = path;
            cwd ??= GroupCwd(System.IO.Path.GetDirectoryName(directory)!);
            summaryModel = ModelName(summary.Field("current_model_id")) ?? summaryModel;
            effort = TokenLogParser.Label(summary.Field("reasoning_effort"));
            var generated = SessionTitle.Clean(summary.Field("generated_title"));
            if (summary.Field("title_is_manual")?.Bool == true) title = generated;
            else if (generated != checkedTitle?.Generated || checkedTitle?.Verified == false)
            {
                var copy = generated is null ? null : CopiesFirstPrompt(generated);
                checkedTitle = (generated, copy is not null);
                title = copy == false ? generated : null;
            }
            windowTokens = LogFields.Count(summary.Field("context_window"));
            isSubagent = summary.Field("session_kind")?.Text?.StartsWith("subagent", StringComparison.Ordinal) == true;
            if (isSubagent)
            {
                parentSessionID = TokenLogParser.Label(summary.Field("parent_session_id")) ?? parentSessionID;
                agentRole ??= TokenLogParser.Label(summary.Field("agent_name"));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// When its title request fails Grok titles the session with the first prompt's opening ten words; such a title is
    /// never shown. The first prompt is read from the head of `updates.jsonl` for this comparison only and is not kept.
    /// Null when the head holds no prompt to compare with (the title then stays hidden until the summary changes).
    bool? CopiesFirstPrompt(string generated)
    {
        byte[] head;
        try
        {
            using var stream = new FileStream(updates.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            head = new byte[Math.Min(stream.Length, 262_144)];
            stream.ReadExactly(head);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
        var prompt = new StringBuilder();
        int? index = null;
        var start = 0;
        while (start < head.Length)
        {
            var newline = Array.IndexOf(head, (byte)'\n', start);
            var end = newline < 0 ? head.Length : newline;
            var line = head.AsSpan(start, end - start);
            start = end + 1;
            if (line.IndexOf(UserChunkMarker) < 0 || Json.Parse(line) is not { ValueKind: JsonValueKind.Object } record
                || record.Field("params")?.Field("update") is not { } update || update.Field("sessionUpdate")?.Text != "user_message_chunk") continue;
            var promptIndex = LogFields.Count(update.Field("_meta")?.Field("promptIndex")) ?? 0;
            if (index is { } first && promptIndex != first) break;
            index = promptIndex;
            if (update.Field("content")?.Field("text")?.Text is { } text) prompt.Append(' ').Append(text);
        }
        if (index is null) return null;
        static string Words(string text) => " " + string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)) + " ";
        return Words(prompt.ToString()).Contains(Words(generated), StringComparison.Ordinal);
    }

    /// A subagent's `meta.json` in its parent's folder names the parent and the agent type. Searched in this cwd folder
    /// first, then in the others (a worktree child runs elsewhere); at most once a minute until found.
    void FindParent(DateTimeOffset now)
    {
        if (!isSubagent || metaFound || parentSearchedAt is { } searched && (now - searched).TotalSeconds < 60) return;
        parentSearchedAt = now;
        var group = System.IO.Path.GetDirectoryName(directory)!;
        var others = TokenDiscovery.Children(System.IO.Path.GetDirectoryName(group)!).OfType<DirectoryInfo>()
            .Select(folder => folder.FullName).Where(folder => folder != group);
        foreach (var folder in others.Prepend(group))
            foreach (var session in TokenDiscovery.Children(folder).OfType<DirectoryInfo>())
            {
                if (session.Name == sessionID) continue;
                var meta = new FileInfo(System.IO.Path.Combine(session.FullName, "subagents", sessionID, "meta.json"));
                if (!meta.Exists) continue;
                metaFound = true;
                JsonElement? record = null;
                try { if (meta.Length <= 262_144) record = Json.Parse(ReadAll(meta.FullName)); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
                parentSessionID = TokenLogParser.Label(record?.Field("parent_session_id")) ?? session.Name;
                agentRole = TokenLogParser.Label(record?.Field("subagent_type")) ?? agentRole;
                return;
            }
    }

    static byte[] ReadAll(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var data = new byte[stream.Length];
        stream.ReadExactly(data);
        return data;
    }

    /// The cwd a session folder group stands for: its URL-decoded name (a rooted path), else the `.cwd` file of a
    /// slug-and-hash name.
    public static string? GroupCwd(string group)
    {
        var decoded = Uri.UnescapeDataString(System.IO.Path.GetFileName(group));
        if (decoded.StartsWith('/') || decoded.Length >= 2 && char.IsAsciiLetter(decoded[0]) && decoded[1] == ':') return decoded;
        try
        {
            var file = new FileInfo(System.IO.Path.Combine(group, ".cwd"));
            if (!file.Exists || file.Length > 4_096) return null;
            var text = Encoding.UTF8.GetString(ReadAll(file.FullName)).Trim();
            return text.Length == 0 ? null : text;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    static string? ModelName(JsonElement? value) => LogFields.Text(value) is { Length: <= 128 } name ? name : null;

    /// Grok Build's tool names (verified: read_file, grep, run_terminal_command, search_replace, list_dir, todo_write,
    /// write, search_tool, get_command_or_subagent_output, kill_command_or_subagent); anything else uses the shared table.
    public static ToolCategory Category(string name) => name switch
    {
        "run_terminal_command" or "get_command_or_subagent_output" or "kill_command_or_subagent" => ToolCategory.Command,
        "read_file" or "write" or "write_file" or "edit_file" or "search_replace" or "apply_patch" or "list_dir" or "grep" or "glob" => ToolCategory.File,
        "web_search" or "web_fetch" or "x_search" or "open_page" or "browser" => ToolCategory.Web,
        "spawn_subagent" => ToolCategory.Agent,
        "search_tool" or "use_tool" => ToolCategory.Mcp,
        "ask_user_question" or "exit_plan_mode" => ToolCategory.Question,
        _ => TokenLogParser.Category(name),
    };
}

/// GrokUnifiedLog (GrokLog.swift): `%GROK_HOME%\logs\unified.jsonl`, shared by every session reader of one Grok home:
/// tailed once (a stat when nothing changed) and kept as each session's recent model calls. Grok trims the file to its
/// newer half in place; lines read again after that are dropped by each session's newest call time. Only counts,
/// durations and times are kept.
public sealed class GrokUnifiedLog
{
    public sealed record Call(int Serial, DateTimeOffset At, int Output, int Prompt, double? ElapsedMs, double? TtftMs, bool Retried);

    static readonly object Gate = new();
    static readonly Dictionary<string, GrokUnifiedLog> Logs = new(StringComparer.Ordinal);
    static readonly byte[] Marker = Encoding.UTF8.GetBytes("\"shell.turn.inference_done\"");

    readonly object gate = new();
    readonly LogLineTail tail;
    readonly Dictionary<string, List<Call>> calls = new(StringComparer.Ordinal);
    int serial;
    bool started;
    bool skippedFirst;
    /// The first line's time when the first read skipped the file's head: calls before it were never seen.
    DateTimeOffset? coverageStart;

    GrokUnifiedLog(string path) => tail = new LogLineTail(path);

    public static GrokUnifiedLog Shared(string path)
    {
        lock (Gate)
        {
            if (Logs.TryGetValue(path, out var log)) return log;
            log = new GrokUnifiedLog(path);
            Logs[path] = log;
            return log;
        }
    }

    public void Refresh(int tailLimit)
    {
        lock (gate)
        {
            var first = !started;
            started = true;
            tail.Read(tailLimit, () => { }, line =>
            {
                if (first && tail.SkippedHead && coverageStart is null && Json.Parse(line) is { } record)
                {
                    skippedFirst = true;
                    coverageStart = LogFields.Date(record.Field("ts"));
                }
                Consume(line);
            });
            if (first && tail.SkippedHead) skippedFirst = true;
        }
    }

    /// Whether every call of a turn that started at `date` was read.
    public bool Covers(DateTimeOffset date)
    {
        lock (gate) return !skippedFirst || coverageStart is { } start && date >= start;
    }

    public List<Call> Calls(string session, int after)
    {
        lock (gate) return calls.TryGetValue(session, out var list) ? [.. list.Where(call => call.Serial > after)] : [];
    }

    void Consume(byte[] line)
    {
        if (line.AsSpan().IndexOf(Marker) < 0 || Json.Parse(line) is not { ValueKind: JsonValueKind.Object } record
            || record.Field("msg")?.Text != "shell.turn.inference_done" || TokenLogParser.Label(record.Field("sid")) is not { } session
            || LogFields.Date(record.Field("ts")) is not { } at || record.Field("ctx") is not { ValueKind: JsonValueKind.Object } context) return;
        if (!calls.TryGetValue(session, out var list)) calls[session] = list = [];
        if (list.Count > 0 && at <= list[^1].At) return;
        serial++;
        list.Add(new Call(serial, at, LogFields.Count(context.Field("completion_tokens")) ?? 0, LogFields.Count(context.Field("prompt_tokens")) ?? 0,
            Milliseconds(context.Field("model_elapsed_ms")), Milliseconds(context.Field("ttft_ms")), (LogFields.Count(context.Field("attempts")) ?? 1) > 1));
        if (list.Count > 256) list.RemoveRange(0, list.Count - 256);
        if (calls.Count > 512)
            calls.Remove(calls.MinBy(pair => pair.Value.Count > 0 ? pair.Value[^1].At : DateTimeOffset.MinValue).Key);
    }

    /// A positive, finite duration in milliseconds below a week; anything else is not a measurement.
    public static double? Milliseconds(JsonElement? value) => value?.Number is { } ms && ms > 0 && ms < 604_800_000 ? ms : null;
}
