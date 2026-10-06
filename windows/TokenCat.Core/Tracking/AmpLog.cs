using System.Text.Json;

namespace TokenCat;

/// AmpLog.swift: one JSON snapshot per thread, `threads\T-<id>.json` (also one folder deeper), parsed whole again when
/// its size, time or file changes. Turn state from the messages' `state` and tool `run.status`, tokens from
/// `messages[].usage.outputTokens` (else `usageLedger.events[]`), project from `env.initial.trees[0]`; no speed.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Amp = new(AmpFiles, path => IsAmpThread(path.Replace('\\', '/').Split('/')[^1]),
        path => new AmpLogReader(path));

    static bool IsAmpThread(string name) => name.StartsWith("T-", StringComparison.Ordinal) && name.EndsWith(".json", StringComparison.Ordinal);

    static List<string> AmpFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var found = new List<FileSystemInfo>();
        foreach (var root in roots)
            foreach (var entry in TokenDiscovery.Children(root))
            {
                if (entry is FileInfo && IsAmpThread(entry.Name)) found.Add(entry);
                else if (entry is DirectoryInfo)
                    found.AddRange(TokenDiscovery.Children(entry.FullName).Where(child => child is FileInfo && IsAmpThread(child.Name)));
            }
        return discovery.Recent(found);
    }
}

public sealed class AmpLogReader(string path) : ITokenLogReader
{
    /// Snapshots past this size are left unread rather than parsed on every change.
    const long MaximumBytes = 67_108_864;
    /// Tool runs that ended; any other status still runs.
    static readonly HashSet<string> FinishedRuns = ["done", "error", "cancelled", "rejected-by-user"];
    (long, long, long)? stamp;
    LogTurnState turn = new();
    string? threadID = Path.GetFileNameWithoutExtension(path);
    string? model;
    string? cwd;
    /// The tree's display name, for a thread whose tree has no file URL.
    string? projectName;

    public bool IsRecent(DateTimeOffset now) => turn.IsRecent(now);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now) =>
        turn.Reading(TokenSource.Amp, id, model, cwd, now) is { } reading
            ? [reading with { SessionID = threadID, Project = cwd is null ? projectName : reading.Project }] : [];

    public void Read(int tailLimit, DateTimeOffset now)
    {
        turn.Clamp(now.AddSeconds(5));
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) return;
            var current = (info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks);
            if (current == stamp) return;
            stamp = current;
            if (info.Length > MaximumBytes) return;
            byte[] data;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                data = new byte[stream.Length];
                stream.ReadExactly(data);
            }
            if (Json.Parse(data) is not { ValueKind: JsonValueKind.Object } thread) return;
            var modified = new DateTimeOffset(info.LastWriteTimeUtc);
            Parse(thread, modified > now.AddSeconds(5) ? now.AddSeconds(5) : modified);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    void Parse(JsonElement thread, DateTimeOffset modified)
    {
        var state = new LogTurnState();
        string? latestModel = null;
        threadID = LogFields.Text(thread.Field("id")) ?? threadID;
        if (LogFields.Objects(thread.Field("env")?.Field("initial")?.Field("trees")) is [var tree, ..])
        {
            if (LogFields.Text(tree.Field("uri")) is { } uri && Uri.TryCreate(uri, UriKind.Absolute, out var file) && file.IsFile) cwd = file.LocalPath;
            projectName = LogFields.Text(tree.Field("displayName"));
        }
        // Ledger outputs by message, for messages that carry no usage of their own.
        var ledger = new Dictionary<int, List<(int Tokens, DateTimeOffset? At, string? Model)>>();
        foreach (var entry in LogFields.Objects(thread.Field("usageLedger")?.Field("events")))
        {
            if (LogFields.Count(entry.Field("toMessageId")) is not { } message || LogFields.Count(entry.Field("tokens")?.Field("output")) is not { } tokens) continue;
            if (!ledger.TryGetValue(message, out var list)) ledger[message] = list = [];
            list.Add((tokens, LogFields.Date(entry.Field("timestamp")), LogFields.Text(entry.Field("model"))));
        }
        var messages = LogFields.Objects(thread.Field("messages"));
        foreach (var message in messages)
        {
            var blocks = LogFields.Objects(message.Field("content"));
            switch (message.Field("role")?.Text)
            {
                case "user":
                    var results = blocks.Where(block => block.Field("type")?.Text == "tool_result").ToList();
                    if (results.Count < blocks.Count) state.Begin(LogFields.Milliseconds(message.Field("meta")?.Field("sentAt")));
                    foreach (var result in results)
                    {
                        if ((LogFields.Text(result.Field("toolUseID")) ?? LogFields.Text(result.Field("tool_use_id"))) is not { } id) continue;
                        var status = result.Field("run")?.Field("status")?.Text;
                        if (status == "blocked-on-user") state.StartRequest(id, null);
                        else if (status is not null && FinishedRuns.Contains(status))
                        {
                            state.FinishRequest(id);
                            state.FinishTool(id, null);
                        }
                    }
                    break;
                case "assistant":
                    var usage = message.Field("usage");
                    var at = LogFields.Date(usage?.Field("timestamp"));
                    state.Resume(at);
                    foreach (var block in blocks.Where(block => block.Field("type")?.Text == "tool_use"))
                        if (LogFields.Text(block.Field("id")) is { } toolId) state.StartTool(toolId, LogFields.Text(block.Field("name")), at);
                    if (usage is { ValueKind: JsonValueKind.Object })
                    {
                        latestModel = LogFields.Text(usage.Value.Field("model")) ?? latestModel;
                        if (LogFields.Count(usage.Value.Field("outputTokens")) is { } tokens) state.AddOutput(tokens, at);
                    }
                    else if (LogFields.Count(message.Field("messageId")) is { } messageId && ledger.TryGetValue(messageId, out var events))
                        foreach (var (tokens, eventAt, eventModel) in events)
                        {
                            latestModel = eventModel ?? latestModel;
                            state.AddOutput(tokens, eventAt);
                        }
                    var messageState = message.Field("state");
                    switch (messageState?.Field("type")?.Text)
                    {
                        case "streaming":
                            state.SetState(state.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Output, at);
                            break;
                        case "cancelled" or "error":
                            state.Close(TokenActivityState.Interrupted, at, latestModel);
                            break;
                        case "complete" when !state.HasPendingTools && messageState?.Field("stopReason")?.Text != "tool_use":
                            state.Close(TokenActivityState.Complete, at, latestModel);
                            break;
                    }
                    break;
            }
        }
        state.Logged(modified);
        // A thread with content but no recorded times still shows, as of its last write.
        if (state.LastActivity is null && messages.Count > 0) state.Touch(modified);
        model = latestModel;
        turn = state;
    }
}
