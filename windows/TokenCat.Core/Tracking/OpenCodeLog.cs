using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace TokenCat;

// OpenCode's SQLite store; mirrors the mac's Providers/OpenCodeLog.swift. Only roles, times, finish reasons, token counts,
// model, agent, cwd and tool names/states are read; message text, tool input and output are never kept.

public sealed partial record TokenLogFormat
{
    /// `opencode.db`, a channel build's `opencode-<channel>.db`, or the `OPENCODE_DB` file. One reader covers every session.
    public static readonly TokenLogFormat OpenCode = new(
        (roots, discovery) => discovery.Recent(roots.SelectMany(TokenDiscovery.Children).Where(entry => entry is FileInfo && OpenCodeLog.IsDatabase(entry.FullName))),
        OpenCodeLog.IsDatabase, path => new OpenCodeLog(path));
}

/// Reads OpenCode sessions from its database, opened read-only (OpenCode writes it in WAL mode).
/// - Re-queried when the database or its WAL changed, and at least every 2 s while a session is in a turn or updated within
///   the hour (NTFS may report a file held open with stale times, rule 8). Then only sessions updated within the hour, with an
///   open turn, or whose `time_updated` moved; a message body is fetched again only when its row's `time_updated` changes.
/// - A message body over 64 KB is never loaded: assistant rows carry no content and stay far smaller, so it is a user message
///   (a summary with file diffs can reach hundreds of MB).
/// - Turn state: an assistant message without `time.completed` is generating (a running tool shows as `tool`, the question
///   tool as `input`); `finish: "tool-calls"` continues the loop; another finish ends the turn (`complete`); an error or no
///   finish at all ends it as `interrupted`.
/// - Speed: per completed assistant message, output + reasoning tokens over the time from `time.created` to its last generated
///   part (text or reasoning end, or a tool's execution start), so a tool's run time is not counted. Request processing rate,
///   first-response wait included; nothing is measured when a part could not be read.
public sealed class OpenCodeLog(string path) : ITokenLogReader
{
    public string Path { get; } = path;
    long[]? signature;
    DateTimeOffset? lastRead;
    Dictionary<string, OpenCodeSession> sessions = new(StringComparer.Ordinal);

    static readonly string? OverridePath = Environment.GetEnvironmentVariable("OPENCODE_DB") is { Length: > 0 } value
        ? System.IO.Path.GetFullPath(value.StartsWith('~') ? AppPaths.Home + value[1..] : value) : null;

    /// A database `Files` lists: OpenCode's default or channel file name, or the `OPENCODE_DB` file.
    public static bool IsDatabase(string path)
    {
        var name = System.IO.Path.GetFileName(path);
        return name == "opencode.db" || (name.StartsWith("opencode-", StringComparison.Ordinal) && name.EndsWith(".db", StringComparison.Ordinal))
            || (OverridePath is not null && string.Equals(path, OverridePath, StringComparison.OrdinalIgnoreCase));
    }

    // Reading

    public void Read(int tailLimit, DateTimeOffset now)
    {
        if (CurrentSignature() is not { } current) return;
        var hot = sessions.Values.Any(session => session.Summary.Open || (now - session.Updated).TotalSeconds <= 3_600);
        if (signature is not null && current.SequenceEqual(signature) && !(hot && lastRead is { } last && (now - last).TotalSeconds >= 2)) return;
        using var database = OpenCodeDatabase.Open(Path);
        if (database is null || !database.Execute("BEGIN")) return;
        try
        {
            var listed = new List<(string Id, string? Parent, string? Directory, string? Agent, string? Model, DateTimeOffset Updated)>();
            const string columns = "id, parent_id, directory, agent, model, time_updated FROM session";
            const string order = "ORDER BY time_updated DESC LIMIT 64";
            void Collect(OpenCodeDatabase.Row row)
            {
                if (row.Text(0) is { } id && row.Date(5) is { } updated) listed.Add((id, row.Text(1), row.Text(2), row.Text(3), row.Text(4), updated));
            }
            // Older schemas lack time_archived.
            if (!database.Query($"SELECT {columns} WHERE time_archived IS NULL {order}", [], Collect)
                && !database.Query($"SELECT {columns} {order}", [], Collect)) return;
            var kept = new Dictionary<string, OpenCodeSession>(StringComparer.Ordinal);
            for (var offset = 0; offset < listed.Count; offset++)
            {
                var row = listed[offset];
                sessions.TryGetValue(row.Id, out var existing);
                if (offset >= 32 && (now - row.Updated).TotalSeconds > 3_600 && existing?.Summary.Open != true) continue;
                var session = existing ?? new OpenCodeSession(row.Id);
                var moved = existing is null || session.Updated != row.Updated;
                session.ParentID = row.Parent;
                session.Directory = row.Directory;
                session.Agent = row.Agent;
                session.SessionModel = row.Model is { } model ? ModelID(model) : null;
                session.Updated = row.Updated;
                if (moved || (now - row.Updated).TotalSeconds <= 3_600 || session.Summary.Open) Refresh(session, database);
                kept[row.Id] = session;
            }
            sessions = kept;
            signature = current;
            lastRead = now;
        }
        finally { database.Execute("COMMIT"); }
    }

    /// Database identity, size and write time, and the WAL's size and write time.
    long[]? CurrentSignature()
    {
        var info = new FileInfo(Path);
        if (!info.Exists) return null;
        var wal = new FileInfo(Path + "-wal");
        return [info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks,
                wal.Exists ? wal.Length : -1, wal.Exists ? wal.LastWriteTimeUtc.Ticks : -1];
    }

    void Refresh(OpenCodeSession session, OpenCodeDatabase database)
    {
        var index = new List<(string Id, DateTimeOffset Created, DateTimeOffset Updated)>();
        if (!database.Query("SELECT id, time_created, time_updated FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 200",
                [session.Id], row => { if (row.Text(0) is { } id && row.Date(1) is { } created && row.Date(2) is { } updated) index.Add((id, created, updated)); }))
            return;
        var messages = new List<OpenCodeMessage>(index.Count);
        foreach (var entry in index)
        {
            if (session.Cache.TryGetValue(entry.Id, out var cached) && cached.Updated == entry.Updated)
            {
                messages.Add(cached);
                continue;
            }
            string? body = null;
            database.Query($"SELECT CASE WHEN {database.SizeOfData} <= 65536 THEN data END FROM message WHERE id = ?", [entry.Id], row => body = row.Text(0));
            messages.Add(OpenCodeMessage.Parse(entry.Id, entry.Created, entry.Updated, body));
        }
        session.Messages = messages;
        session.Cache = messages.GroupBy(message => message.Id, StringComparer.Ordinal).ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);
        session.OpenParts = messages.FirstOrDefault() is { Role: OpenCodeRole.Assistant, Completed: null } open ? Parts(open.Id, database) : null;
        if (messages.FirstOrDefault(message => message is { Role: OpenCodeRole.Assistant, Completed: not null, Failed: false, Generated: > 0 }) is { } measured)
        {
            if (session.Speed is not { } speed || speed.MessageID != measured.Id || speed.Updated != measured.Updated)
                session.Speed = (measured.Id, measured.Updated, Parts(measured.Id, database) is { } parts ? Measurement(measured, parts) : null);
        }
        else session.Speed = null;
        session.Summary = OpenCodeSummary.Of(session);
    }

    static List<OpenCodePart>? Parts(string message, OpenCodeDatabase database)
    {
        var parts = new List<OpenCodePart>();
        return database.Query("SELECT time_updated, CASE WHEN " + database.SizeOfData + " <= 262144 THEN data END FROM part WHERE message_id = ? ORDER BY id",
            [message], row => { if (row.Date(0) is { } updated) parts.Add(OpenCodePart.Parse(updated, row.Text(1))); }) ? parts : null;
    }

    /// Output + reasoning over created → last generated part; null when a part was unreadable or no time was recorded.
    static TokenSpeedMeasurement? Measurement(OpenCodeMessage message, List<OpenCodePart> parts)
    {
        if (message.Completed is not { } completed || parts.Any(part => !part.Readable)) return null;
        var ends = parts.Select(part => part.Type switch
        {
            "text" or "reasoning" => part.End ?? part.Updated,
            "tool" => part.ToolStart,
            _ => (DateTimeOffset?)null,
        }).OfType<DateTimeOffset>().ToList();
        if (ends.Count == 0) return null;
        var milliseconds = (ends.Max() - message.Created).TotalMilliseconds;
        if (!double.IsFinite(milliseconds) || milliseconds <= 0) return null;
        return new TokenSpeedMeasurement(new TelemetryReading
        {
            Provider = TokenSource.OpenCode,
            At = completed,
            Model = message.Model,
            OutputTokens = message.Generated,
            RequestDurationMs = Math.Round(milliseconds),
            RequestDurationIncludesRetries = parts.Any(part => part.Type == "retry"),
        });
    }

    // Readings

    public bool IsRecent(DateTimeOffset now) =>
        sessions.Values.Any(session => session.Summary.Open || session.Summary.LastLogAt is { } at && (now - at).TotalSeconds <= 3_600);

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        var readings = new List<TokenReading>();
        foreach (var session in sessions.Values)
        {
            var summary = session.Summary;
            if (summary.LastActivity is not { } activity) continue;
            var ceiling = now.AddSeconds(5);
            var lastActivity = activity < ceiling ? activity : ceiling;
            var newest = summary.LastLogAt is { } logged && logged > activity ? logged : activity;
            var liveAt = newest < ceiling ? newest : ceiling;
            var age = (now - liveAt).TotalSeconds;
            var horizon = summary.WaitsForInput ? 86_400 : summary.ToolName is not null ? 900 : 600;
            var active = summary.Open && age is >= -5 && age <= horizon;
            var state = !summary.Open ? summary.State
                : summary.WaitsForInput ? active ? TokenActivityState.Input : TokenActivityState.Unfinished
                : active ? summary.State
                : age <= 1_800 ? TokenActivityState.Stale : TokenActivityState.Unfinished;
            var cwd = summary.Cwd ?? session.Directory;
            var tool = summary.Open ? summary.ToolName : null;
            readings.Add(new TokenReading(TokenSource.OpenCode, $"{id}#{session.Id}")
            {
                SessionID = session.Id,
                IsSubagent = session.ParentID is not null,
                ParentSessionID = session.ParentID,
                AgentID = session.ParentID is not null ? session.Id : null,
                AgentRole = session.ParentID is not null ? Label(summary.Agent ?? session.Agent) : null,
                Project = string.IsNullOrEmpty(cwd) ? null : ProjectName(cwd),
                ProjectPath = string.IsNullOrEmpty(cwd) ? null : cwd,
                Model = summary.Model ?? session.SessionModel,
                Context = summary.Context,
                LastActivity = lastActivity,
                LastLogAt = liveAt,
                MeasurementAt = summary.Completion?.At ?? lastActivity,
                Active = active,
                ActivityState = state,
                ToolName = tool,
                ToolCategory = tool is null ? null : Category(tool),
                CurrentTurnStartedAt = summary.Open ? summary.StartedAt : null,
                CurrentTurnOutputTokens = summary.Open ? summary.TurnOutput : null,
                LastOutputAt = summary.Outputs.Count > 0 ? summary.Outputs[^1].At : null,
                LastOutputDelta = summary.Outputs.Count > 0 ? summary.Outputs[^1].Tokens : null,
                RecentOutputs = [.. summary.Outputs.Where(e => (now - e.At).TotalSeconds is >= -5 and <= TokenTracker.RecentOutputWindow)],
                LastOutputTokens = summary.Completion?.Output,
                SpeedMeasurement = session.Speed?.Measurement,
                SampledAt = now,
            });
        }
        return readings;
    }

    /// The cwd's last component, for `/` and `\` paths alike.
    static string ProjectName(string cwd)
    {
        var trimmed = cwd.TrimEnd('/', '\\');
        var cut = trimmed.LastIndexOfAny(['/', '\\']);
        return cut >= 0 && cut < trimmed.Length - 1 ? trimmed[(cut + 1)..] : trimmed;
    }

    static string? Label(string? value) => value is null ? null : TokenLogParser.Label(JsonSerializer.SerializeToElement(value));

    /// OpenCode's built-in tool names (lowercase); MCP tools are `<server>_<tool>` and stay `Other`.
    public static ToolCategory Category(string name) => name switch
    {
        "bash" => ToolCategory.Command,
        "read" or "write" or "edit" or "multiedit" or "patch" or "apply_patch" or "grep" or "glob" or "list" or "ls" or "lsp" => ToolCategory.File,
        "webfetch" or "websearch" or "codesearch" => ToolCategory.Web,
        "task" => ToolCategory.Agent,
        "question" => ToolCategory.Question,
        _ => ToolCategory.Other,
    };

    static string? ModelID(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > 4_096) return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            return Short(document.RootElement.Field("id")) ?? Short(document.RootElement.Field("modelID"));
        }
        catch (JsonException) { return null; }
    }

    internal static string? Short(JsonElement? value) => value?.Text is { Length: > 0 and <= 256 } text ? text : null;

    internal static DateTimeOffset? Milliseconds(JsonElement? value) =>
        value?.Number is { } number && number > 0 && number < 253_402_300_800_000 ? DateTimeOffset.FromUnixTimeMilliseconds((long)number) : null;

    internal static int Count(JsonElement? value) => value?.Number is { } number && number > 0 ? (int)Math.Min(number, int.MaxValue) : 0;
}

enum OpenCodeRole { User, Assistant, Other }

/// One message's metadata; never its text.
sealed record OpenCodeMessage(string Id, DateTimeOffset Created, DateTimeOffset Updated)
{
    public OpenCodeRole Role { get; init; } = OpenCodeRole.Other;
    public DateTimeOffset? Completed { get; init; }
    public string? Finish { get; init; }
    public bool Failed { get; init; }
    public string? Model { get; init; }
    public string? ParentID { get; init; }
    public string? Cwd { get; init; }
    public string? Agent { get; init; }
    /// Output + reasoning tokens (OpenCode records them apart).
    public int Generated { get; init; }
    /// Input + cache read + cache write of this request.
    public int Context { get; init; }

    public static OpenCodeMessage Parse(string id, DateTimeOffset created, DateTimeOffset updated, string? body)
    {
        // Only a user message can exceed the body cap (see OpenCodeLog).
        if (body is null) return new(id, created, updated) { Role = OpenCodeRole.User };
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            var role = root.Field("role")?.Text switch { "user" => OpenCodeRole.User, "assistant" => OpenCodeRole.Assistant, _ => OpenCodeRole.Other };
            if (role == OpenCodeRole.Other) return new(id, created, updated);
            var tokens = root.Field("tokens");
            var cache = tokens?.Field("cache");
            return new(id, created, updated)
            {
                Role = role,
                Completed = OpenCodeLog.Milliseconds(root.Field("time")?.Field("completed")),
                Finish = OpenCodeLog.Short(root.Field("finish")),
                Failed = root.Field("error") is { ValueKind: not JsonValueKind.Null },
                Model = OpenCodeLog.Short(root.Field("modelID")) ?? OpenCodeLog.Short(root.Field("model")?.Field("modelID")),
                ParentID = OpenCodeLog.Short(root.Field("parentID")),
                Cwd = root.Field("path")?.Field("cwd")?.Text,
                Agent = OpenCodeLog.Short(root.Field("agent")) ?? OpenCodeLog.Short(root.Field("mode")),
                Generated = OpenCodeLog.Count(tokens?.Field("output")) + OpenCodeLog.Count(tokens?.Field("reasoning")),
                Context = OpenCodeLog.Count(tokens?.Field("input")) + OpenCodeLog.Count(cache?.Field("read")) + OpenCodeLog.Count(cache?.Field("write")),
            };
        }
        catch (JsonException) { return new(id, created, updated); }
    }
}

/// One part's type, tool name and state, and its times; never its text, input or output.
sealed record OpenCodePart(DateTimeOffset Updated, bool Readable, string? Type, string? Tool, string? Status, DateTimeOffset? ToolStart, DateTimeOffset? End)
{
    public static OpenCodePart Parse(DateTimeOffset updated, string? body)
    {
        if (body is null) return new(updated, false, null, null, null, null, null);
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            var state = root.Field("state");
            return new(updated, true, OpenCodeLog.Short(root.Field("type")), OpenCodeLog.Short(root.Field("tool")), OpenCodeLog.Short(state?.Field("status")),
                OpenCodeLog.Milliseconds(state?.Field("time")?.Field("start")), OpenCodeLog.Milliseconds(root.Field("time")?.Field("end")));
        }
        catch (JsonException) { return new(updated, false, null, null, null, null, null); }
    }
}

sealed class OpenCodeSession(string id)
{
    public string Id { get; } = id;
    public string? ParentID { get; set; }
    public string? Directory { get; set; }
    public string? Agent { get; set; }
    public string? SessionModel { get; set; }
    public DateTimeOffset Updated { get; set; } = DateTimeOffset.MinValue;
    /// Newest first, at most 200.
    public List<OpenCodeMessage> Messages { get; set; } = [];
    public Dictionary<string, OpenCodeMessage> Cache { get; set; } = new(StringComparer.Ordinal);
    /// Parts of the newest message while it is an assistant message still generating.
    public List<OpenCodePart>? OpenParts { get; set; }
    public (string MessageID, DateTimeOffset Updated, TokenSpeedMeasurement? Measurement)? Speed { get; set; }
    public OpenCodeSummary Summary { get; set; } = new();
}

/// What a session's messages say, apart from the clock.
sealed record OpenCodeSummary
{
    public bool Open { get; init; }
    public TokenActivityState State { get; init; } = TokenActivityState.Idle;
    public string? ToolName { get; init; }
    public bool WaitsForInput { get; init; }
    public DateTimeOffset? StartedAt { get; init; }
    public int? TurnOutput { get; init; }
    public (int Output, DateTimeOffset At)? Completion { get; init; }
    public List<TokenOutputEvent> Outputs { get; init; } = [];
    public DateTimeOffset? LastActivity { get; init; }
    public DateTimeOffset? LastLogAt { get; init; }
    public string? Model { get; init; }
    public string? Cwd { get; init; }
    public string? Agent { get; init; }
    public TokenContextUsage? Context { get; init; }

    public static OpenCodeSummary Of(OpenCodeSession session)
    {
        var messages = session.Messages;
        if (messages.Count == 0) return new();
        var newest = messages[0];
        var assistants = messages.Where(message => message.Role == OpenCodeRole.Assistant).ToList();
        var parts = session.OpenParts ?? [];
        var latest = assistants.FirstOrDefault(message => message.Completed is not null && message.Context > 0);

        // The person's message that opened a turn, and its output when the whole turn is in the window.
        (DateTimeOffset Start, int Output)? Turn(string? user) =>
            user is not null && messages.FirstOrDefault(message => message.Id == user && message.Role == OpenCodeRole.User) is { } opener
                ? (opener.Created, assistants.Where(message => message.ParentID == user).Sum(message => message.Generated)) : null;

        var open = false;
        var state = TokenActivityState.Idle;
        string? toolName = null;
        var waits = false;
        DateTimeOffset? startedAt = null;
        int? turnOutput = null;
        switch (newest.Role)
        {
            case OpenCodeRole.User:
                (open, state, startedAt, turnOutput) = (true, TokenActivityState.Working, newest.Created, 0);
                break;
            case OpenCodeRole.Assistant:
                if (newest.Completed is null)
                {
                    (open, state) = (true, TokenActivityState.Working);
                    var running = parts.Where(part => part.Type == "tool" && part.Status is "pending" or "running").ToList();
                    if ((running.LastOrDefault(part => part.Tool == "question") ?? running.LastOrDefault()) is { } tool)
                    {
                        toolName = tool.Tool;
                        waits = tool.Tool == "question";
                        state = waits ? TokenActivityState.Input : TokenActivityState.Tool;
                    }
                    else if (parts.LastOrDefault(part => part.Type is "text" or "reasoning" or "tool")?.Type == "text") state = TokenActivityState.Output;
                }
                else if (newest.Failed || newest.Finish is null) state = TokenActivityState.Interrupted;
                else if (newest.Finish == "tool-calls") (open, state) = (true, TokenActivityState.Working);
                else state = TokenActivityState.Complete;
                if (open && Turn(newest.ParentID) is { } turn) (startedAt, turnOutput) = (turn.Start, turn.Output);
                break;
        }
        // The newest turn that ended normally, fully seen.
        (int, DateTimeOffset)? completion = null;
        if (assistants.FirstOrDefault(message => message is { Completed: not null, Failed: false, Finish: not null and not "tool-calls" }) is { Completed: { } at } last
            && Turn(last.ParentID) is { Output: > 0 } finished)
            completion = (finished.Output, at);

        DateTimeOffset? lastLogAt = messages.Max(message => message.Updated);
        foreach (var part in parts) if (part.Updated > lastLogAt) lastLogAt = part.Updated;
        return new()
        {
            Open = open,
            State = state,
            ToolName = toolName,
            WaitsForInput = waits,
            StartedAt = startedAt,
            TurnOutput = turnOutput,
            Completion = completion,
            Outputs = [.. assistants.Where(message => message is { Completed: not null, Generated: > 0 })
                .Select(message => new TokenOutputEvent(message.Completed!.Value, message.Generated)).OrderBy(e => e.At)],
            LastActivity = messages.Max(message => message.Completed ?? message.Created),
            LastLogAt = lastLogAt,
            Model = assistants.Select(message => message.Model).FirstOrDefault(model => model is not null),
            Cwd = assistants.Select(message => message.Cwd).FirstOrDefault(cwd => cwd is not null),
            Agent = assistants.Select(message => message.Agent).FirstOrDefault(agent => agent is not null),
            Context = latest is { Completed: { } recorded } ? new TokenContextUsage(latest.Context, null, recorded, null) : null,
        };
    }
}

/// A connection to an SQLite database through the OS library: winsqlite3.dll (Windows 10+); on a mac or Linux host (checks)
/// the system libsqlite3. OpenCode's database is only ever opened read-only; `create` is for check fixtures.
sealed class OpenCodeDatabase : IDisposable
{
    const string Library = "winsqlite3";
    const int Ok = 0, RowReady = 100, Done = 101, Integer = 1, Null = 5;
    const int OpenReadOnly = 0x1, OpenReadWrite = 0x2, OpenCreate = 0x4, OpenNoMutex = 0x8000;
    static readonly IntPtr Transient = new(-1);
    IntPtr handle;

    /// Bytes of `data` without loading it (`octet_length`, SQLite 3.43+); older libraries load the value to measure it.
    public string SizeOfData { get; }

    static OpenCodeDatabase()
    {
        try { NativeLibrary.SetDllImportResolver(typeof(OpenCodeDatabase).Assembly, Resolve); }
        catch (InvalidOperationException) { } // another resolver owns this assembly; Windows needs none
    }

    static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (name != Library || OperatingSystem.IsWindows()) return IntPtr.Zero;
        foreach (var candidate in new[] { "/usr/lib/libsqlite3.dylib", "libsqlite3.so.0", "libsqlite3" })
            if (NativeLibrary.TryLoad(candidate, out var loaded)) return loaded;
        return IntPtr.Zero;
    }

    OpenCodeDatabase(IntPtr handle)
    {
        this.handle = handle;
        sqlite3_busy_timeout(handle, 250);
        SizeOfData = Query("SELECT octet_length('')", [], _ => { }) ? "octet_length(data)" : "length(CAST(data AS BLOB))";
    }

    public static OpenCodeDatabase? Open(string path, bool create = false)
    {
        try
        {
            var flags = (create ? OpenReadWrite | OpenCreate : OpenReadOnly) | OpenNoMutex;
            var status = sqlite3_open_v2(Utf8(path), out var handle, flags, IntPtr.Zero);
            if (status == Ok && handle != IntPtr.Zero) return new OpenCodeDatabase(handle);
            if (handle != IntPtr.Zero) sqlite3_close_v2(handle);
            return null;
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException) { return null; }
    }

    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        sqlite3_close_v2(handle);
        handle = IntPtr.Zero;
    }

    public bool Execute(string sql) => sqlite3_exec(handle, Utf8(sql), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == Ok;

    /// Runs one statement with text, integer or null parameters; false when it could not be prepared or stepped to the end.
    public bool Query(string sql, object?[] bindings, Action<Row> row)
    {
        if (sqlite3_prepare_v2(handle, Utf8(sql), -1, out var statement, IntPtr.Zero) != Ok || statement == IntPtr.Zero) return false;
        try
        {
            for (var index = 0; index < bindings.Length; index++)
                _ = bindings[index] switch
                {
                    string text => sqlite3_bind_text(statement, index + 1, Utf8(text), -1, Transient),
                    long number => sqlite3_bind_int64(statement, index + 1, number),
                    _ => sqlite3_bind_null(statement, index + 1),
                };
            while (true)
            {
                switch (sqlite3_step(statement))
                {
                    case RowReady: row(new Row(statement)); break;
                    case Done: return true;
                    default: return false;
                }
            }
        }
        finally { sqlite3_finalize(statement); }
    }

    public readonly struct Row(IntPtr statement)
    {
        public string? Text(int column)
        {
            if (sqlite3_column_type(statement, column) == Null) return null;
            var text = sqlite3_column_text(statement, column);
            return text == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(text, sqlite3_column_bytes(statement, column));
        }

        public DateTimeOffset? Date(int column) =>
            sqlite3_column_type(statement, column) == Integer && sqlite3_column_int64(statement, column) is > 0 and < 253_402_300_800_000 and var value
                ? DateTimeOffset.FromUnixTimeMilliseconds(value) : null;
    }

    static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value + "\0");

    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr database, int flags, IntPtr vfs);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_close_v2(IntPtr database);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_busy_timeout(IntPtr database, int milliseconds);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_exec(IntPtr database, byte[] sql, IntPtr callback, IntPtr argument, IntPtr error);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_prepare_v2(IntPtr database, byte[] sql, int bytes, out IntPtr statement, IntPtr tail);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_bind_text(IntPtr statement, int index, byte[] text, int bytes, IntPtr destructor);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_bind_null(IntPtr statement, int index);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_step(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_finalize(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_column_type(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern long sqlite3_column_int64(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_column_bytes(IntPtr statement, int column);
}
