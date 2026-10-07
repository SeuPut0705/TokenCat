using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TokenCat;

/// CursorLog.swift: Cursor (the IDE's agent and the cursor-agent CLI) writes one transcript per conversation, keyed by its
/// composer id, under `projects\<slug>\agent-transcripts\`: `<id>\<id>.jsonl` (older builds `<id>.jsonl` or a `.txt`), and
/// subagents in `<parent>\subagents\<id>.jsonl`.
/// - JSONL records `{role, message: {content: [text | tool_use]}}` and `{type: "turn_ended", status}`; no times, ids,
///   model or tokens. The person's message opens a turn, an assistant step with tool uses runs them until the next step,
///   `turn_ended` closes it (`success` completes it, anything else interrupts it). A legacy `.txt` transcript marks blocks
///   with `user:` / `assistant:` lines and `[Tool call] <name>` / `[Tool result]`; it has no end record, so assistant text
///   after the last tool completes the turn (a later block reopens it).
/// - Times: records carry none, so lines read together take the file's modification time; on the first read only the
///   last line does (earlier lines are of unknown age). Cursor prefixes newer prompts with `<timestamp>Friday, Jul 17,
///   2026, 12:26 AM (UTC+9)</timestamp>`, which dates the turn's start to the minute.
/// - The IDE's `%APPDATA%\Cursor\User\globalStorage\state.vscdb` (read-only, re-queried when its file or WAL changes) adds per
///   composer: the title Cursor generated or the person gave (`name`; never the prompt), a blocking pending action (an
///   approval: `Input`), the workspace folder, the model of the latest request (`default` is Auto and not a model), the
///   context occupied (`contextTokensUsed` of `contextTokenLimit`), the subagent type and its update time (liveness only).
/// - The cursor-agent CLI's `chats\<hash>\<id>\store.db` names the model (`meta` row `lastUsedModel`).
/// - Project: the IDE's worktree or workspace folder; else the transcript folder's slug (the path with every separator
///   as `-`) matched against existing folders.
/// - Tokens and speed: Cursor keeps no reliable token counts locally, so no output, turn total or speed is reported.
public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Cursor = new(CursorFiles, CursorLog.IsTranscript, path => new CursorLogReader(path));

    static List<string> CursorFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var main = new List<FileSystemInfo>();
        var subagents = new List<FileSystemInfo>();
        foreach (var project in roots.SelectMany(root => TokenDiscovery.Children(root)).OfType<DirectoryInfo>())
            foreach (var entry in TokenDiscovery.Children(Path.Combine(project.FullName, "agent-transcripts")))
            {
                if (entry is not DirectoryInfo)
                {
                    if (CursorLog.IsTranscriptName(entry.Name)) main.Add(entry);
                    continue;
                }
                foreach (var child in TokenDiscovery.Children(entry.FullName))
                {
                    if (child is FileInfo && (child.Name == entry.Name + ".jsonl" || child.Name == entry.Name + ".txt")) main.Add(child);
                    else if (child is DirectoryInfo && child.Name == "subagents")
                        subagents.AddRange(TokenDiscovery.Children(child.FullName).Where(file => file is FileInfo && file.Extension == ".jsonl"));
                }
            }
        return [.. discovery.Recent(main), .. discovery.Recent(subagents)];
    }
}

public static class CursorLog
{
    /// `<id>.jsonl` / `<id>.txt` directly in `agent-transcripts`.
    public static bool IsTranscriptName(string name) =>
        name.EndsWith(".jsonl", StringComparison.Ordinal) || name.EndsWith(".txt", StringComparison.Ordinal);

    /// A path `Files` would list: `agent-transcripts\<id>.(jsonl|txt)`, `agent-transcripts\<id>\<id>.(jsonl|txt)` or
    /// `agent-transcripts\<parent>\subagents\<id>.jsonl`.
    public static bool IsTranscript(string path)
    {
        var parts = path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        var marker = Array.LastIndexOf(parts, "agent-transcripts");
        if (marker < 0 || parts.Length == 0 || !IsTranscriptName(parts[^1])) return false;
        var name = parts[^1];
        var id = name.EndsWith(".jsonl", StringComparison.Ordinal) ? name[..^6] : name[..^4];
        return (parts.Length - marker) switch
        {
            2 => true,
            3 => parts[marker + 1] == id,
            4 => parts[marker + 2] == "subagents" && name.EndsWith(".jsonl", StringComparison.Ordinal),
            _ => false,
        };
    }

    /// Cursor's tool names; anything else falls back to the shared table.
    public static ToolCategory Category(string name) => name switch
    {
        "Shell" or "Terminal" or "run_terminal_cmd" => ToolCategory.Command,
        "Read" or "Write" or "StrReplace" or "Delete" or "Glob" or "Grep" or "SemanticSearch" or "ReadLints" or "EditNotebook" or "ApplyPatch"
            or "LS" or "read_file" or "edit_file" or "grep_search" or "file_search" or "codebase_search" or "list_dir" => ToolCategory.File,
        "WebSearch" or "WebFetch" or "web_search" => ToolCategory.Web,
        "Task" or "Subagent" => ToolCategory.Agent,
        "AskQuestion" => ToolCategory.Question,
        _ => TokenLogParser.Category(name),
    };

    /// A prompt's leading `<timestamp>…</timestamp>` tag (minute precision, local time with its UTC offset).
    public static DateTimeOffset? PromptTime(string text)
    {
        var head = text.Length > 160 ? text[..160] : text;
        if (!head.StartsWith("<timestamp>", StringComparison.Ordinal)) return null;
        var close = head.IndexOf("</timestamp>", StringComparison.Ordinal);
        if (close < 0) return null;
        var zone = head.IndexOf(" (UTC", 0, close, StringComparison.Ordinal);
        if (zone < 0) return null;
        var local = head[11..zone];
        var offset = head[(zone + 5)..close];
        if (!offset.EndsWith(')')) return null;
        offset = offset[..^1];
        var seconds = 0;
        if (offset.Length > 0)
        {
            if (offset[0] is not ('+' or '-')) return null;
            var parts = offset[1..].Split(':');
            if (parts.Length is < 1 or > 2 || !int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var hours) || hours > 14)
                return null;
            var minutes = 0;
            if (parts.Length == 2 && (!int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out minutes) || minutes > 59)) return null;
            seconds = (hours * 3_600 + minutes * 60) * (offset[0] == '-' ? -1 : 1);
        }
        if (!DateTime.TryParseExact(local, "dddd, MMM d, yyyy, h:mm tt", CultureInfo.InvariantCulture, DateTimeStyles.None, out var at)) return null;
        return new DateTimeOffset(at, TimeSpan.FromSeconds(seconds)).ToUniversalTime();
    }

    /// A model name; Cursor's `default` (Auto) names none.
    public static string? Model(string? value) => value is { Length: > 0 and <= 128 } && value != "default" ? value : null;

    /// `TokenLogParser.Label` for a string read from SQLite.
    internal static string? Label(string? value) => value is null ? null : TokenLogParser.Label(JsonSerializer.SerializeToElement(value));
}

public sealed class CursorLogReader : ITokenLogReader
{
    enum Kind { Prompt, Step, Results, Ended, LegacyUser, LegacyAssistant, LegacyTool, LegacyResult, LegacyText }

    readonly record struct Event(Kind Kind, DateTimeOffset? Stamped = null, IReadOnlyList<string?>? Tools = null, bool Success = false);

    readonly LogLineTail tail;
    readonly string sessionID;
    readonly string? parentID;
    readonly bool legacy;
    /// The `projects\<slug>` folder name.
    readonly string? slug;
    readonly CursorIDEStore ideStore;
    readonly string[] chatFolders;
    /// The CLI's `agent-cli-state.json`, which names the folders it ran in.
    readonly string? cliState;
    readonly string home;
    LogTurnState turn = new();
    readonly List<string> tools = [];
    int toolCount;
    /// Legacy transcripts: the block now being written is the assistant's.
    bool legacyAssistant;
    CursorComposer? composer;
    CursorProject.Resolved? project;
    string? chatStore;
    DateTimeOffset? chatSearchedAt;
    long[]? chatSignature;
    string? chatModel;

    public CursorLogReader(string path)
    {
        tail = new LogLineTail(path);
        legacy = path.EndsWith(".txt", StringComparison.Ordinal);
        sessionID = Path.GetFileNameWithoutExtension(path);
        var full = Path.GetFullPath(path);
        var parts = full.Split(['/', '\\']);
        var marker = Array.LastIndexOf(parts, "agent-transcripts");
        parentID = marker >= 0 && parts.Length - marker == 4 && parts[marker + 2] == "subagents" ? parts[marker + 1] : null;
        slug = marker >= 1 ? parts[marker - 1] : null;
        // <cursor dir>\projects\<slug>\agent-transcripts\…; ~\.cursor names the home whose IDE storage goes with it.
        var cursorDir = marker >= 3 ? string.Join(Path.DirectorySeparatorChar, parts[..(marker - 2)]) : null;
        if (cursorDir == "") cursorDir = Path.DirectorySeparatorChar.ToString();
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        home = cursorDir is not null && Path.GetFileName(cursorDir) == ".cursor" ? Path.GetDirectoryName(cursorDir) ?? profile : profile;
        var appData = string.Equals(Path.TrimEndingDirectorySeparator(home), Path.TrimEndingDirectorySeparator(profile), StringComparison.OrdinalIgnoreCase)
            && Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData) is { Length: > 0 } roaming
            ? roaming : Path.Combine(home, "AppData", "Roaming");
        ideStore = CursorIDEStore.At(Path.Combine(appData, "Cursor", "User", "globalStorage", "state.vscdb"));
        chatFolders = [.. new[] { cursorDir is null ? null : Path.Combine(cursorDir, "chats"), Path.Combine(home, ".config", "cursor", "chats") }.OfType<string>()];
        cliState = cursorDir is null ? null : Path.Combine(cursorDir, "agent-cli-state.json");
    }

    public bool IsRecent(DateTimeOffset now) => turn.IsRecent(now);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        var cwd = composer?.Cwd ?? project?.Path;
        if (turn.Reading(TokenSource.Cursor, id, composer?.Model ?? chatModel, cwd, now) is not { } reading) return [];
        if (composer?.Cwd is null)
            reading = reading with { Project = project?.Name ?? slug, ProjectPath = project is { Exists: true } found ? found.Path : null };
        return [reading with
        {
            ToolCategory = reading.ToolName is { } name ? CursorLog.Category(name) : reading.ToolCategory,
            SessionID = sessionID,
            IsSubagent = parentID is not null,
            ParentSessionID = parentID,
            AgentID = parentID is null ? null : sessionID,
            AgentRole = parentID is null ? null : CursorLog.Label(composer?.SubagentType),
            Title = composer?.Title,
            Context = composer?.Context,
            CurrentTurnOutputTokens = null,
        }];
    }

    public void Read(int tailLimit, DateTimeOffset now)
    {
        turn.Clamp(now.AddSeconds(5));
        var initial = tail.Modified is null;
        var events = new List<Event>();
        tail.Read(tailLimit, () =>
        {
            turn = new LogTurnState();
            tools.Clear();
            legacyAssistant = false;
        }, line =>
        {
            if ((legacy ? LegacyEvent(line) : JsonEvent(line)) is { } parsed) events.Add(parsed);
        });
        if (events.Count > 0 && tail.Modified is { } modified)
        {
            var written = modified > now.AddSeconds(5) ? now.AddSeconds(5) : modified;
            for (var index = 0; index < events.Count; index++)
                Apply(events[index], initial && index < events.Count - 1 ? null : written, written);
            if (legacy && legacyAssistant && events[^1].Kind == Kind.LegacyText && !turn.HasPendingTools)
                turn.Close(TokenActivityState.Complete, written, null);
        }
        Enrich(now);
    }

    static Event? JsonEvent(byte[] data)
    {
        if (Json.Parse(data) is not { ValueKind: JsonValueKind.Object } record) return null;
        if (record.Field("type")?.Text == "turn_ended") return new Event(Kind.Ended, Success: record.Field("status")?.Text == "success");
        if (record.Field("message") is not { ValueKind: JsonValueKind.Object } message) return null;
        var content = message.Field("content");
        var blocks = LogFields.Objects(content);
        switch (record.Field("role")?.Text ?? message.Field("role")?.Text)
        {
            case "user":
                if (blocks.Count > 0 && blocks.All(block => block.Field("type")?.Text == "tool_result")) return new Event(Kind.Results);
                IEnumerable<string?> texts = content?.ValueKind == JsonValueKind.String ? [content.Value.Text]
                    : blocks.Where(block => block.Field("type")?.Text == "text").Select(block => block.Field("text")?.Text);
                return new Event(Kind.Prompt, Stamped: texts.Select(text => text is null ? null : CursorLog.PromptTime(text)).FirstOrDefault(at => at is not null));
            case "assistant":
                return new Event(Kind.Step, Tools: [.. blocks.Where(block => block.Field("type")?.Text == "tool_use").Select(block => LogFields.Text(block.Field("name")))]);
            default:
                return null;
        }
    }

    static Event? LegacyEvent(byte[] data)
    {
        var right = Encoding.UTF8.GetString(data).TrimEnd();
        if (right == "user:") return new Event(Kind.LegacyUser);
        if (right == "assistant:") return new Event(Kind.LegacyAssistant);
        var trimmed = right.Trim(' ', '\t');
        if (trimmed.Length == 0) return null;
        if (trimmed.StartsWith("[Tool call] ", StringComparison.Ordinal))
        {
            var name = trimmed[12..];
            return new Event(Kind.LegacyTool, Tools: [name.Length > 128 ? name[..128] : name]);
        }
        return trimmed.StartsWith("[Tool result]", StringComparison.Ordinal) ? new Event(Kind.LegacyResult) : new Event(Kind.LegacyText);
    }

    /// `date` is null for a line of unknown age (before the last line of the first read).
    void Apply(Event e, DateTimeOffset? date, DateTimeOffset written)
    {
        turn.Logged(date);
        switch (e.Kind)
        {
            case Kind.Prompt:
                FinishTools(date);
                turn.Begin(e.Stamped is { } stamped ? (stamped < written ? stamped : written) : date);
                break;
            case Kind.Step:
                turn.Resume(date);
                FinishTools(date);
                if (e.Tools is not { Count: > 0 } names) turn.SetState(TokenActivityState.Working, date);
                else foreach (var name in names) StartTool(name, date);
                break;
            case Kind.Results:
                FinishTools(date);
                break;
            case Kind.Ended:
                turn.Resume(date);
                tools.Clear();
                turn.Close(e.Success ? TokenActivityState.Complete : TokenActivityState.Interrupted, date, null);
                break;
            case Kind.LegacyUser:
                legacyAssistant = false;
                FinishTools(date);
                turn.Begin(date);
                break;
            case Kind.LegacyAssistant:
                legacyAssistant = true;
                turn.Resume(date);
                turn.SetState(turn.HasPendingTools ? TokenActivityState.Tool : TokenActivityState.Working, date);
                break;
            case Kind.LegacyTool:
                turn.Resume(date);
                StartTool(e.Tools?[0], date);
                break;
            case Kind.LegacyResult:
                FinishTools(date);
                break;
            case Kind.LegacyText:
                turn.Touch(date);
                break;
        }
    }

    /// Tool uses carry no ids; the next step or result record means they returned.
    void StartTool(string? name, DateTimeOffset? date)
    {
        toolCount++;
        var id = $"cursor-tool-{toolCount}";
        tools.Add(id);
        turn.StartTool(id, name, date);
    }

    void FinishTools(DateTimeOffset? date)
    {
        foreach (var id in tools) turn.FinishTool(id, date);
        tools.Clear();
    }

    void Enrich(DateTimeOffset now)
    {
        composer = ideStore.Composer(sessionID, now);
        if (composer?.Updated is { } updated) turn.Logged(updated > now.AddSeconds(5) ? now.AddSeconds(5) : updated);
        if (composer?.Pending == true) turn.StartRequest("cursor-pending-action", null); else turn.FinishRequest("cursor-pending-action");
        if (composer?.Cwd is null && slug is not null)
        {
            IEnumerable<string> recorded = cliState is null ? ideStore.Workspaces : ideStore.Workspaces.Concat(CursorProject.CliWorkspaces(cliState, home));
            project = CursorProject.Match(slug, recorded) is { } folder ? new CursorProject.Resolved(folder, true) : CursorProject.Resolve(slug, now);
        }
        if (composer?.Model is null) ReadChatModel(now);
    }

    /// The cursor-agent CLI's `chats\<hash>\<id>\store.db`: `meta['0']` is hex-encoded JSON whose `lastUsedModel` names the
    /// model. Only that field is read; the store is looked for again every 5 minutes until found.
    void ReadChatModel(DateTimeOffset now)
    {
        if (chatStore is null)
        {
            if (chatSearchedAt is { } searched && (now - searched).TotalSeconds < 300 && now >= searched) return;
            chatSearchedAt = now;
            chatStore = chatFolders.SelectMany(folder => TokenDiscovery.Children(folder).OfType<DirectoryInfo>())
                .Select(hash => Path.Combine(hash.FullName, sessionID, "store.db")).FirstOrDefault(File.Exists);
        }
        if (chatStore is null || OpenCodeDatabase.Signature(chatStore) is not { } signature
            || chatSignature is not null && signature.SequenceEqual(chatSignature)) return;
        using var database = CursorIDEStore.Open(chatStore);
        if (database is null) return;
        string? value = null;
        if (!database.Query("SELECT CAST(value AS TEXT) FROM meta WHERE key = '0'", [], row => value = row.Text(0))) return;
        chatSignature = signature;
        if (value is null || value.Length > 1_048_576 || value.Length % 2 != 0) return;
        byte[] bytes;
        try { bytes = Convert.FromHexString(value); }
        catch (FormatException) { return; }
        chatModel = Json.Parse(bytes) is { } meta ? CursorLog.Model(meta.Field("lastUsedModel")?.Text) : null;
    }
}

/// What the IDE's database says about one composer. Only metadata; never message text.
public sealed record CursorComposer
{
    public string? Title { get; init; }
    public string? Model { get; init; }
    public string? Cwd { get; init; }
    public bool Pending { get; init; }
    public DateTimeOffset? Updated { get; init; }
    public string? SubagentType { get; init; }
    public TokenContextUsage? Context { get; init; }
}

/// The IDE's `state.vscdb`, shared by every transcript reader of one home. Re-queried when the database or its WAL changed
/// (at most once per sample), and then only for composers a reader asked about within 10 minutes.
/// - Headers: the `composerHeaders` table (current builds), else the `composer.composerHeaders` JSON in `ItemTable`.
/// - `composerData:<id>` in `cursorDiskKV` (model, worktree, context) is parsed again only when its header moved.
sealed class CursorIDEStore
{
    static readonly Dictionary<string, CursorIDEStore> Stores = new(StringComparer.Ordinal);

    public static CursorIDEStore At(string path)
    {
        lock (Stores)
        {
            if (!Stores.TryGetValue(path, out var store)) Stores[path] = store = new CursorIDEStore(path);
            return store;
        }
    }

    /// Read-only; as an immutable snapshot when Cursor quit and took its `-wal`/`-shm` along (a read-only connection
    /// cannot recreate them). The snapshot misses later writes, so it is opened again whenever the stamp changes.
    public static OpenCodeDatabase? Open(string path) => OpenCodeDatabase.Open(path, immutable: !File.Exists(path + "-wal"));

    readonly string path;
    long[]? signature;
    DateTimeOffset? sampledAt;
    Dictionary<string, DateTimeOffset> wanted = new(StringComparer.Ordinal);
    readonly Dictionary<string, CursorComposer> composers = new(StringComparer.Ordinal);
    /// The header stamp each composer's `composerData` was read at.
    readonly Dictionary<string, string> dataStamps = new(StringComparer.Ordinal);
    /// Every composer's workspace folder (at most 512): what a transcript's slug is matched against.
    public IReadOnlyList<string> Workspaces { get; private set; } = [];

    CursorIDEStore(string path) => this.path = path;

    public CursorComposer? Composer(string id, DateTimeOffset now)
    {
        var known = wanted.ContainsKey(id);
        wanted[id] = now;
        if (sampledAt != now || !known)
        {
            sampledAt = now;
            wanted = wanted.Where(entry => (now - entry.Value).TotalSeconds <= 600).ToDictionary(StringComparer.Ordinal);
            Refresh(known ? null : id);
        }
        return composers.GetValueOrDefault(id);
    }

    /// `onlyNew`: a composer asked about for the first time, queried alone when nothing else changed.
    void Refresh(string? onlyNew)
    {
        if (OpenCodeDatabase.Signature(path) is not { } current)
        {
            signature = null;
            composers.Clear();
            dataStamps.Clear();
            Workspaces = [];
            return;
        }
        List<string> ids;
        if (signature is null || !current.SequenceEqual(signature)) ids = [.. wanted.Keys];
        else if (onlyNew is not null) ids = [onlyNew];
        else return;
        if (ids.Count == 0) return;
        using var database = Open(path);
        if (database is null || !database.Execute("BEGIN")) return;
        try
        {
            var tables = new HashSet<string>(StringComparer.Ordinal);
            if (!database.Query("SELECT name FROM sqlite_master WHERE type = 'table'", [], row => { if (row.Text(0) is { } name) tables.Add(name); })
                || Headers(ids, tables, database) is not { } headers) return;
            if (signature is null || !current.SequenceEqual(signature))
            {
                if (WorkspaceList(tables, database) is not { } folders) return;
                Workspaces = folders;
            }
            foreach (var id in ids)
            {
                var composer = composers.GetValueOrDefault(id) ?? new CursorComposer();
                var header = headers.GetValueOrDefault(id);
                composer = composer with
                {
                    Title = header?.Title, Pending = header?.Pending ?? false, Updated = header?.Updated, SubagentType = header?.SubagentType,
                };
                var stamp = header?.Stamp ?? "";
                if (header is null || dataStamps.GetValueOrDefault(id) != stamp)
                {
                    (string? Model, string? Worktree, TokenContextUsage? Context) data = (null, null, null);
                    if (tables.Contains("cursorDiskKV"))
                    {
                        if (ComposerData(id, database) is not { } read) return;
                        data = read;
                    }
                    dataStamps[id] = stamp;
                    composer = composer with { Model = data.Model, Context = data.Context, Cwd = data.Worktree ?? header?.Workspace };
                }
                if (header is null && composer.Model is null && composer.Cwd is null) composers.Remove(id);
                else composers[id] = composer;
            }
            signature = current;
        }
        finally { database.Execute("COMMIT"); }
    }

    /// Null when the database refused the read.
    static List<string>? WorkspaceList(HashSet<string> tables, OpenCodeDatabase database)
    {
        static string Folder(string value) => $"substr(json_extract({value}, '$.workspaceIdentifier.uri.fsPath'), 1, 4096)";
        string sql;
        if (tables.Contains("composerHeaders")) sql = $"SELECT DISTINCT {Folder("value")} FROM composerHeaders LIMIT 512";
        else if (tables.Contains("ItemTable"))
            sql = $"SELECT DISTINCT {Folder("j.value")} FROM ItemTable, json_each(CAST(ItemTable.value AS TEXT), '$.allComposers') j "
                + "WHERE ItemTable.key = 'composer.composerHeaders' LIMIT 512";
        else return [];
        var found = new List<string>();
        return database.Query(sql, [], row => { if (row.Text(0) is { Length: > 0 } folder) found.Add(folder); }) ? found : null;
    }

    sealed record Header(string? Title, bool Pending, string? Workspace, DateTimeOffset? Updated, string? SubagentType, string Stamp);

    /// The `composerHeaders` table of current builds, else the `composer.composerHeaders` JSON in `ItemTable`. Null when the
    /// database refused the read.
    static Dictionary<string, Header>? Headers(List<string> ids, HashSet<string> tables, OpenCodeDatabase database)
    {
        var marks = string.Join(",", Enumerable.Repeat("?", ids.Count));
        static string Fields(string value) =>
            $"substr(json_extract({value}, '$.name'), 1, 1024), json_extract({value}, '$.hasBlockingPendingActions'), "
            + $"substr(json_extract({value}, '$.workspaceIdentifier.uri.fsPath'), 1, 4096)";
        var found = new Dictionary<string, Header>(StringComparer.Ordinal);
        void Collect(OpenCodeDatabase.Row row)
        {
            if (row.Text(0) is not { } id) return;
            var updated = row.Int64(4);
            var percent = row.Double(6) ?? -1;
            found[id] = new Header(SessionTitle.Clean(row.Text(1)), row.Int64(2) == 1, row.Text(3) is { Length: > 0 } workspace ? workspace : null,
                updated is > 0 and < 253_402_300_800_000 ? DateTimeOffset.FromUnixTimeMilliseconds(updated.Value) : null, row.Text(5),
                $"{updated ?? 0}|{percent.ToString("R", CultureInfo.InvariantCulture)}");
        }
        object?[] bindings = [.. ids];
        if (tables.Contains("composerHeaders"))
            return database.Query($"SELECT composerId, {Fields("value")}, lastUpdatedAt, substr(subagentTypeName, 1, 64), "
                + $"json_extract(value, '$.contextUsagePercent') FROM composerHeaders WHERE composerId IN ({marks})", bindings, Collect) ? found : null;
        if (!tables.Contains("ItemTable")) return found;
        return database.Query($"SELECT json_extract(j.value, '$.composerId'), {Fields("j.value")}, json_extract(j.value, '$.lastUpdatedAt'), "
            + "substr(json_extract(j.value, '$.subagentTypeName'), 1, 64), json_extract(j.value, '$.contextUsagePercent') "
            + "FROM ItemTable, json_each(CAST(ItemTable.value AS TEXT), '$.allComposers') j "
            + $"WHERE ItemTable.key = 'composer.composerHeaders' AND json_extract(j.value, '$.composerId') IN ({marks})", bindings, Collect) ? found : null;
    }

    /// The model of the latest request (the newest user bubble's, else the composer's setting), the worktree and the
    /// context occupied. Null when the database refused the read; empty values when there is no such composer.
    static (string? Model, string? Worktree, TokenContextUsage? Context)? ComposerData(string id, OpenCodeDatabase database)
    {
        (string? Model, string? Worktree, TokenContextUsage? Context) result = (null, null, null);
        const string sql = """
            SELECT json_extract(v, '$.modelConfig.modelName'), json_extract(v, '$.contextTokensUsed'), json_extract(v, '$.contextTokenLimit'),
                   json_extract(v, '$.lastUpdatedAt'), substr(json_extract(v, '$.gitWorktree.worktreePath'), 1, 4096),
                   (SELECT json_extract(CAST(b.value AS TEXT), '$.modelInfo.modelName') FROM cursorDiskKV b
                    WHERE b.key = 'bubbleId:' || ?1 || ':' || (SELECT json_extract(h.value, '$.bubbleId')
                        FROM json_each(v, '$.fullConversationHeadersOnly') h WHERE json_extract(h.value, '$.type') = 1 ORDER BY h.key DESC LIMIT 1))
            FROM (SELECT CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key = 'composerData:' || ?1)
            """;
        if (!database.Query(sql, [id], row =>
            {
                result.Model = CursorLog.Model(row.Text(5)) ?? CursorLog.Model(row.Text(0));
                result.Worktree = row.Text(4) is { Length: > 0 } worktree ? worktree : null;
                if (row.Int64(1) is > 0 and <= int.MaxValue and var used && row.Date(3) is { } updated)
                    result.Context = new TokenContextUsage((int)used, row.Int64(2) is > 0 and <= int.MaxValue and var window ? (int)window : null, updated, null);
            })) return null;
        return result;
    }
}

/// The folder a `projects\<slug>` name stands for. Cursor writes the path with every separator (and `.`, `_`, spaces, the
/// drive's colon) as `-`, so the slug is lossy. First it is matched against folders Cursor itself recorded (`Match`: every
/// IDE composer's workspace and the CLI's `agent-cli-state.json`), which opens no other folder. Else it is matched against
/// existing folders from the root (`C:\` for a leading one-letter token on Windows) down (`Decode`); a unique full match is
/// the project. (The mac walk also skips folders macOS guards with a privacy prompt; Windows has none.) When nothing
/// matches, the deepest folder reached plus the rest of the slug (joined with `-`) names it, so a deleted temporary folder
/// still shows its own name; a slug matching no folder at all (`empty-window`, a window number) is shown as is.
public static class CursorProject
{
    public sealed record Resolved(string Path, bool Exists)
    {
        public string Name => System.IO.Path.GetFileName(System.IO.Path.TrimEndingDirectorySeparator(Path));
    }

    /// Resolutions by slug for 10 minutes.
    static readonly Dictionary<string, (Resolved? Value, DateTimeOffset At)> Cache = new(StringComparer.Ordinal);
    static readonly Dictionary<string, ((long, long, long) Stamp, List<string> Folders)> CliStates = new(StringComparer.Ordinal);

    /// The one recorded folder whose path reads as `slug`; null when none or several do.
    public static string? Match(string slug, IEnumerable<string> folders)
    {
        var tokens = slug.Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0) return null;
        var comparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
        // macOS's /var and /tmp live in /private; Cursor names them without it (`var-folders-…`).
        var found = folders.Select(folder => folder.StartsWith("/private/", StringComparison.Ordinal) ? folder[8..] : folder)
            .Where(folder => NameTokens(folder).Any(parts => parts.SequenceEqual(tokens, comparer))).Distinct(StringComparer.Ordinal).Take(2).ToList();
        return found.Count == 1 ? found[0] : null;
    }

    /// `workerIdsByDisplayName` keys of the CLI's state file ("~/Desktop/GitHub/app @ host"), re-read when its stamp changes.
    public static List<string> CliWorkspaces(string path, string home)
    {
        lock (CliStates)
        {
            var info = new FileInfo(path);
            if (!info.Exists) return [];
            var stamp = (info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks);
            if (CliStates.TryGetValue(path, out var cached) && cached.Stamp == stamp) return cached.Folders;
            var folders = new List<string>();
            try
            {
                if (info.Length <= 1_048_576 && Json.Parse(File.ReadAllBytes(path))?.Field("workerIdsByDisplayName") is { ValueKind: JsonValueKind.Object } names)
                    foreach (var name in names.EnumerateObject().Take(512).Select(property => property.Name))
                    {
                        var folder = name;
                        var at = folder.LastIndexOf(" @ ", StringComparison.Ordinal);
                        if (at >= 0) folder = folder[..at];
                        if (folder == "~" || folder.StartsWith("~/", StringComparison.Ordinal) || folder.StartsWith(@"~\", StringComparison.Ordinal))
                            folder = home + folder[1..];
                        if (Path.IsPathRooted(folder)) folders.Add(folder);
                    }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            CliStates[path] = (stamp, folders);
            return folders;
        }
    }

    public static Resolved? Resolve(string slug, DateTimeOffset now, string? root = null)
    {
        var key = (root ?? "") + "\n" + slug;
        lock (Cache)
        {
            if (Cache.TryGetValue(key, out var cached) && Math.Abs((now - cached.At).TotalSeconds) < 600) return cached.Value;
            var value = Decode(slug, root);
            if (Cache.Count > 512) Cache.Clear();
            Cache[key] = (value, now);
            return value;
        }
    }

    public static Resolved? Decode(string slug, string? root = null)
    {
        var tokens = slug.Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0) return null;
        var start = 0;
        if (root is null)
        {
            root = "/";
            if (OperatingSystem.IsWindows())
            {
                if (tokens[0].Length != 1 || !char.IsAsciiLetter(tokens[0][0])) return null;
                root = char.ToUpperInvariant(tokens[0][0]) + @":\";
                start = 1;
            }
        }
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var matches = new List<string>();
        (string Path, int Consumed)? deepest = start > 0 ? (root, start) : null;
        var budget = 256;
        void Walk(string folder, int consumed)
        {
            if (matches.Count >= 2 || budget <= 0) return;
            if (consumed == tokens.Length) { matches.Add(folder); return; }
            if (consumed > (deepest?.Consumed ?? 0)) deepest = (folder, consumed);
            budget--;
            string[] names;
            try { names = [.. Directory.EnumerateFileSystemEntries(folder).Select(entry => System.IO.Path.GetFileName(entry))]; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return; }
            var candidates = new List<(string Name, int Count)>();
            foreach (var name in names)
                foreach (var parts in NameTokens(name))
                    if (parts.Length > 0 && consumed + parts.Length <= tokens.Length
                        && parts.Select((part, index) => string.Equals(part, tokens[consumed + index], comparison)).All(same => same))
                    {
                        candidates.Add((name, parts.Length));
                        break;
                    }
            foreach (var candidate in candidates.OrderByDescending(c => c.Count).ThenBy(c => c.Name, StringComparer.Ordinal))
            {
                var path = System.IO.Path.Combine(folder, candidate.Name);
                if (Directory.Exists(path)) Walk(path, consumed + candidate.Count);
            }
        }
        Walk(root, start);
        if (matches.Count > 0) return new Resolved(matches[0], true);
        if (deepest is not { } best) return null;
        return new Resolved(System.IO.Path.Combine(best.Path, string.Join("-", tokens[best.Consumed..])), false);
    }

    /// A folder name's slug tokens: split at every character other than an ASCII letter or digit, and (for names with
    /// other letters) at every character other than a letter or digit.
    static IEnumerable<string[]> NameTokens(string name)
    {
        var ascii = Split(name, c => char.IsAsciiLetterOrDigit(c));
        yield return ascii;
        var unicode = Split(name, char.IsLetterOrDigit);
        if (!unicode.SequenceEqual(ascii, StringComparer.Ordinal)) yield return unicode;
    }

    static string[] Split(string name, Func<char, bool> keep)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        foreach (var c in name)
        {
            if (keep(c)) { current.Append(c); continue; }
            if (current.Length > 0) parts.Add(current.ToString());
            current.Clear();
        }
        if (current.Length > 0) parts.Add(current.ToString());
        return [.. parts];
    }
}
