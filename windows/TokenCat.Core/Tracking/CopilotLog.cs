using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TokenCat;

/// CopilotLog.swift: GitHub Copilot CLI's `session-state\<session>\events.jsonl` (older builds:
/// `session-state\<session>.jsonl`). Turn rules, tokens (`assistant.message.outputTokens`; the per-call
/// `assistant.usage` is ephemeral, so no speed), `inuse.<PID>.lock` liveness and the workspace.yaml `cwd:` fallback
/// match the mac. Title: workspace.yaml `name:` (a rename), else `summary:` (the name the CLI generates with a model); the
/// yaml is read again whenever it changes. The `session.title_changed` event is ephemeral and never written.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Copilot = new(CopilotFiles, path =>
    {
        var parts = path.Replace('\\', '/').Split('/');
        return parts[^1] == "events.jsonl"
            || (parts[^1].EndsWith(".jsonl", StringComparison.Ordinal) && parts.Length > 1 && parts[^2] == "session-state");
    }, path => new CopilotLogReader(path));

    static List<string> CopilotFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var found = new List<FileSystemInfo>();
        foreach (var root in roots)
            foreach (var entry in TokenDiscovery.Children(root))
            {
                if (entry is FileInfo && entry.Extension == ".jsonl") found.Add(entry);
                else if (entry is DirectoryInfo && new FileInfo(Path.Combine(entry.FullName, "events.jsonl")) is { Exists: true } events)
                    found.Add(events);
            }
        return discovery.Recent(found);
    }
}

public sealed class CopilotLogReader : ITokenLogReader
{
    static readonly HashSet<string> InputTools = ["ask_user"];
    readonly LogLineTail tail;
    readonly string? folder;
    LogTurnState turn = new(InputTools);
    string? sessionID;
    string? model;
    string? effort;
    string? cwd;
    (long, long, long)? workspaceStamp;
    string? title;
    /// The last model reply of the open turn requested tools, so a turn_end continues the agent loop.
    bool requestedTools;
    /// Lock files were seen for this session, so their absence means the process is gone.
    bool lockSeen;

    public CopilotLogReader(string path)
    {
        tail = new LogLineTail(path);
        var isFolderLog = Path.GetFileName(path) == "events.jsonl";
        folder = isFolderLog ? Path.GetDirectoryName(path) : null;
        sessionID = isFolderLog ? Path.GetFileName(folder) : Path.GetFileNameWithoutExtension(path);
    }

    public bool IsRecent(DateTimeOffset now) => turn.IsRecent(now);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now) =>
        turn.Reading(TokenSource.Copilot, id, model, cwd, now) is { } reading
            ? [reading with { SessionID = sessionID, Effort = effort, Title = title }] : [];

    public void Read(int tailLimit, DateTimeOffset now)
    {
        turn.Clamp(now.AddSeconds(5));
        var initial = tail.Modified is null;
        tail.Read(tailLimit, () =>
        {
            turn = new LogTurnState(InputTools);
            model = null;
            effort = null;
            requestedTools = false;
        }, Consume);
        if (initial && tail.SkippedHead && tail.FirstLine() is { } header) ConsumeHeader(header);
        ReadWorkspace();
        if (turn.TurnOpen && ProcessEnded()) turn.Close(TokenActivityState.Unfinished, null, model);
    }

    /// Identity, project and model from a `session.start` the tail skipped; no turn state.
    void ConsumeHeader(byte[] data)
    {
        if (Json.Parse(data) is not { } record || record.Field("type")?.Text != "session.start" || record.Field("data") is not { } payload) return;
        sessionID = LogFields.Text(payload.Field("sessionId")) ?? sessionID;
        cwd ??= LogFields.Text(payload.Field("context")?.Field("cwd"));
        model ??= LogFields.Text(payload.Field("selectedModel"));
    }

    void Consume(byte[] data)
    {
        if (Json.Parse(data) is not { } record || record.Field("type")?.Text is not { } type || record.Field("ephemeral")?.Bool == true) return;
        var payload = record.Field("data") ?? default;
        var date = LogFields.Date(record.Field("timestamp"));
        turn.Logged(date);
        // Subagent events: their output counts toward this session, their lifecycle is the parent's running tool.
        var fromSubagent = record.Field("agentId")?.Text is not null || payload.Field("parentToolCallId")?.Text is not null;
        switch (type)
        {
            case "session.start" or "session.resume":
                sessionID = LogFields.Text(payload.Field("sessionId")) ?? sessionID;
                cwd = LogFields.Text(payload.Field("context")?.Field("cwd")) ?? cwd;
                model = LogFields.Text(payload.Field("selectedModel")) ?? model;
                effort = TokenLogParser.Label(payload.Field("reasoningEffort")) ?? effort;
                if (type == "session.resume") turn.Close(TokenActivityState.Interrupted, date, model);
                break;
            case "session.model_change":
                model = LogFields.Text(payload.Field("newModel")) ?? model;
                effort = TokenLogParser.Label(payload.Field("reasoningEffort")) ?? effort;
                break;
            case "session.context_changed":
                cwd = LogFields.Text(payload.Field("cwd")) ?? cwd;
                break;
            case "user.message":
                if (fromSubagent) return;
                requestedTools = false;
                turn.Begin(date);
                break;
            case "assistant.turn_start":
                if (fromSubagent) return;
                turn.Resume(date);
                requestedTools = false;
                turn.SetState(turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, date);
                break;
            case "assistant.message":
                if (!fromSubagent)
                {
                    if (LogFields.Text(payload.Field("model")) is { } used) model = used;
                    turn.Resume(date);
                    requestedTools = payload.Field("toolRequests") is { ValueKind: JsonValueKind.Array } requests && requests.GetArrayLength() > 0;
                    turn.SetState(requestedTools ? TokenActivityState.Working : TokenActivityState.Output, date);
                }
                if (LogFields.Count(payload.Field("outputTokens")) is { } tokens) turn.AddOutput(tokens, date);
                break;
            case "tool.execution_start":
                if (fromSubagent || LogFields.Text(payload.Field("toolCallId")) is not { } startId) return;
                turn.Resume(date);
                turn.StartTool(startId, LogFields.Text(payload.Field("toolName")), date);
                break;
            case "tool.execution_complete":
                if (fromSubagent || LogFields.Text(payload.Field("toolCallId")) is not { } doneId) return;
                if (LogFields.Text(payload.Field("model")) is { } toolModel) model = toolModel;
                turn.FinishTool(doneId, date);
                break;
            case "permission.requested":
                if (LogFields.Text(payload.Field("requestId")) is not { } requestId) return;
                turn.Resume(date);
                turn.StartRequest(requestId, date);
                break;
            case "permission.completed":
                if (LogFields.Text(payload.Field("requestId")) is { } answered) turn.FinishRequest(answered);
                break;
            case "assistant.turn_end":
                if (!fromSubagent && !requestedTools && !turn.HasPendingTools) turn.Close(TokenActivityState.Complete, date, model);
                break;
            case "session.task_complete":
                if (!fromSubagent) turn.Close(TokenActivityState.Complete, date, model);
                break;
            case "abort" or "session.error":
                if (!fromSubagent) turn.Close(TokenActivityState.Interrupted, date, model);
                break;
            case "session.shutdown":
                model = LogFields.Text(payload.Field("currentModel")) ?? model;
                turn.Close(TokenActivityState.Interrupted, date, model);
                break;
        }
    }

    /// `cwd:` (when the events named none), `name:` and `summary:` from workspace.yaml (plain, quoted or block scalars
    /// on top-level keys), whenever its size, time or file changed; its other keys are never kept.
    void ReadWorkspace()
    {
        if (folder is null) return;
        try
        {
            var file = new FileInfo(Path.Combine(folder, "workspace.yaml"));
            if (!file.Exists) return;
            var current = (file.CreationTimeUtc.Ticks, file.Length, file.LastWriteTimeUtc.Ticks);
            if (current == workspaceStamp) return;
            workspaceStamp = current;
            if (file.Length > 65_536) return;
            byte[] data;
            using (var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                data = new byte[stream.Length];
                stream.ReadExactly(data);
            }
            var values = YamlValues(Encoding.UTF8.GetString(data), ["cwd", "name", "summary"]);
            if (cwd is null && values.GetValueOrDefault("cwd") is { Length: > 0 } path) cwd = path;
            title = SessionTitle.Clean(values.GetValueOrDefault("name")) ?? SessionTitle.Clean(values.GetValueOrDefault("summary"));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// Top-level scalar values of a flat YAML mapping, for the given keys only.
    public static Dictionary<string, string> YamlValues(string text, HashSet<string> keys)
    {
        var lines = text.Split(["\r\n", "\n", "\r"], StringSplitOptions.None);
        var values = new Dictionary<string, string>();
        var index = 0;
        while (index < lines.Length)
        {
            var line = lines[index];
            index += 1;
            var colon = line.IndexOf(':');
            if (colon < 0 || char.IsWhiteSpace(line[0])) continue;
            var key = line[..colon];
            if (!keys.Contains(key)) continue;
            var value = line[(colon + 1)..].Trim();
            if (value.Length > 0 && value[0] is '|' or '>')
            {
                // A block scalar: the indented lines that follow, joined (SessionTitle folds them to one line anyway).
                var block = new List<string>();
                while (index < lines.Length && (lines[index].Length == 0 || char.IsWhiteSpace(lines[index][0])))
                {
                    block.Add(lines[index].Trim());
                    index += 1;
                }
                values[key] = string.Join("\n", block);
            }
            else if (value.Length >= 2 && value[0] == '"' && value[^1] == '"')
                values[key] = Json.Parse(Encoding.UTF8.GetBytes(value))?.Text ?? value[1..^1];
            else if (value.Length >= 2 && value[0] == '\'' && value[^1] == '\'')
                values[key] = value[1..^1].Replace("''", "'", StringComparison.Ordinal);
            else values[key] = value;
        }
        return values;
    }

    /// The CLI keeps `inuse.<PID>.lock` in the session folder while it runs; a crash can leave one behind.
    bool ProcessEnded()
    {
        if (folder is null) return false;
        var pids = new List<int>();
        try
        {
            foreach (var file in Directory.EnumerateFiles(folder, "inuse.*.lock"))
                if (int.TryParse(Path.GetFileName(file)[6..^5], NumberStyles.None, CultureInfo.InvariantCulture, out var pid)) pids.Add(pid);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
        if (pids.Count == 0) return lockSeen;
        lockSeen = true;
        return !pids.Any(Alive);
    }

    static bool Alive(int pid)
    {
        if (pid <= 0) return false;
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        // An exited or unknown PID throws ArgumentException; one we may not inspect still runs.
        catch (System.ComponentModel.Win32Exception) { return true; }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException) { return false; }
    }
}
