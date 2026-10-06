using System.Text.Json;

namespace TokenCat;

/// DroidLog.swift: Factory Droid's `sessions\<project-slug>\<session>.jsonl` (older builds: directly in `sessions\`) with
/// `<session>.settings.json` beside it. Turn state from the JSONL messages; tokens from growth of the settings file's
/// `tokenUsage.outputTokens` session total at its write time (the first total read is a baseline); model and effort from
/// the settings file; no speed.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Droid = new(DroidFiles, path => path.EndsWith(".jsonl", StringComparison.Ordinal),
        path => new DroidLogReader(path));

    static List<string> DroidFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var found = new List<FileSystemInfo>();
        foreach (var root in roots)
            foreach (var entry in TokenDiscovery.Children(root))
            {
                if (entry is FileInfo && entry.Extension == ".jsonl") found.Add(entry);
                else if (entry is DirectoryInfo)
                    found.AddRange(TokenDiscovery.Children(entry.FullName).Where(child => child is FileInfo && child.Extension == ".jsonl"));
            }
        return discovery.Recent(found);
    }
}

public sealed class DroidLogReader(string path) : ITokenLogReader
{
    readonly LogLineTail tail = new(path);
    readonly string settingsPath = Path.ChangeExtension(path, ".settings.json");
    (long, long, long)? settingsStamp;
    LogTurnState turn = new();
    string? sessionID = Path.GetFileNameWithoutExtension(path);
    string? cwd;
    string? model;
    string? effort;
    /// The settings file's output total at its latest read; null until one was read.
    int? outputTotal;

    public bool IsRecent(DateTimeOffset now) => turn.IsRecent(now);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now) =>
        turn.Reading(TokenSource.Droid, id, model, cwd, now) is { } reading ? [reading with { SessionID = sessionID, Effort = effort }] : [];

    public void Read(int tailLimit, DateTimeOffset now)
    {
        turn.Clamp(now.AddSeconds(5));
        var initial = tail.Modified is null;
        tail.Read(tailLimit, () =>
        {
            turn = new LogTurnState();
            outputTotal = null;
            settingsStamp = null;
        }, Consume);
        if (initial && tail.SkippedHead && tail.FirstLine() is { } header && Json.Parse(header) is { } record
            && record.Field("type")?.Text == "session_start")
        {
            sessionID = LogFields.Text(record.Field("id")) ?? sessionID;
            cwd = LogFields.Text(record.Field("cwd")) ?? cwd;
        }
        // After the log, so a turn opened in this read starts from the total before its output.
        ReadSettings(now);
    }

    void Consume(byte[] data)
    {
        if (Json.Parse(data) is not { } record) return;
        var date = LogFields.Date(record.Field("timestamp"));
        turn.Logged(date);
        switch (record.Field("type")?.Text)
        {
            case "session_start":
                sessionID = LogFields.Text(record.Field("id")) ?? sessionID;
                cwd = LogFields.Text(record.Field("cwd")) ?? cwd;
                break;
            case "message" when record.Field("message") is { ValueKind: JsonValueKind.Object } message:
                var content = message.Field("content");
                var blocks = LogFields.Objects(content);
                switch (message.Field("role")?.Text)
                {
                    case "user":
                        var results = blocks.Where(block => block.Field("type")?.Text == "tool_result").ToList();
                        foreach (var result in results)
                            if (LogFields.Text(result.Field("tool_use_id")) is { } id) turn.FinishTool(id, date);
                        var prompt = content?.ValueKind == JsonValueKind.String || results.Count < blocks.Count;
                        if (prompt && message.Field("visibility")?.Text != "llm_only") turn.Begin(date, whole: outputTotal is not null);
                        break;
                    case "assistant":
                        turn.Resume(date);
                        var tools = blocks.Where(block => block.Field("type")?.Text == "tool_use").ToList();
                        foreach (var tool in tools)
                            if (LogFields.Text(tool.Field("id")) is { } toolId) turn.StartTool(toolId, LogFields.Text(tool.Field("name")), date);
                        if (tools.Count == 0 && !turn.HasPendingTools && blocks.Any(block => block.Field("type")?.Text == "text"))
                            turn.Close(TokenActivityState.Complete, date, model);
                        else if (tools.Count == 0)
                            turn.SetState(turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, date);
                        break;
                }
                break;
        }
    }

    void ReadSettings(DateTimeOffset now)
    {
        try
        {
            var info = new FileInfo(settingsPath);
            if (!info.Exists) return;
            var current = (info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks);
            if (current == settingsStamp) return;
            settingsStamp = current;
            if (info.Length > 1_048_576) return;
            byte[] data;
            using (var stream = new FileStream(settingsPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                data = new byte[stream.Length];
                stream.ReadExactly(data);
            }
            if (Json.Parse(data) is not { } settings) return;
            var modified = new DateTimeOffset(info.LastWriteTimeUtc);
            var written = modified > now.AddSeconds(5) ? now.AddSeconds(5) : modified;
            model = ModelName(settings.Field("model")) ?? model;
            if (TokenLogParser.Label(settings.Field("reasoningEffort")) is { } level) effort = level == "none" ? null : level;
            if (LogFields.Count(settings.Field("tokenUsage")?.Field("outputTokens")) is not { } total) return;
            if (outputTotal is { } previous && total > previous)
            {
                turn.Logged(written);
                turn.AddOutput(total - previous, written);
            }
            outputTotal = total;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// Bring-your-own models read `custom:<name>-[<Provider>]-<n>`; the name alone is shown.
    public static string? ModelName(JsonElement? value)
    {
        if (LogFields.Text(value) is not { } name) return null;
        if (name.StartsWith("custom:", StringComparison.Ordinal)) name = name[7..];
        var bracket = name.LastIndexOf("-[", StringComparison.Ordinal);
        if (bracket >= 0 && name.IndexOf(']', bracket) >= 0) name = name[..bracket];
        return name.Length == 0 ? null : name;
    }
}
