using System.Reflection;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Json;

namespace TokenCat;

// OpenCode's SQLite store and the apps built on it; mirrors the mac's Providers/OpenCodeLog.swift. Only roles, times, finish
// reasons, token counts, model, agent, cwd, tool names/states and the session's generated or renamed title are read; message
// text, tool input and output are never kept.

public sealed partial record TokenLogFormat
{
    /// The SQLite store of OpenCode and of the apps built on it (`OpenCodeApp`): `<app>.db`, a channel build's
    /// `<app>-<channel>.db`, or the `<APP>_DB` file. One reader covers every session in it.
    public static readonly TokenLogFormat OpenCode = new(
        (roots, discovery) => discovery.Recent(roots.SelectMany(TokenDiscovery.Children).Where(entry => entry is FileInfo && OpenCodeLog.IsDatabase(entry.FullName))),
        OpenCodeLog.IsDatabase, path => new OpenCodeLog(path));
}

/// OpenCode and the apps built on its store, which keep its schema in their own data folder: Kilo Code (the Kilo CLI and the
/// extension rebuilt on it) and MiMo Code.
/// - `Name`: the data folder's name and the database file stem: `<name>.db`, a channel build's `<name>-<channel>.db`.
/// - `Variable`: the variable naming the database file, resolved like the app does: rooted, else inside the data folder.
/// - `Client`: `TokenReading.ClientName` of its rows; null for OpenCode itself.
public sealed record OpenCodeApp(string Name, string Variable, string? Client)
{
    public static readonly IReadOnlyList<OpenCodeApp> All =
        [new("opencode", "OPENCODE_DB", null), new("kilo", "KILO_DB", "Kilo Code"), new("mimocode", "MIMOCODE_DB", "MiMo Code")];

    /// `XDG_DATA_HOME\<name>`, else ~\.local\share\<name> (xdg-basedir, Windows too); MiMo Code's `MIMOCODE_HOME\data`.
    public string DataFolder(string home, Func<string, string?> env) =>
        Name == "mimocode" && TokenProvider.EnvPath(home, env, "MIMOCODE_HOME") is { } root ? Path.Combine(root, "data")
            : Path.Combine(TokenProvider.DataHome(home, env), Name);

    /// The `Variable` file: a rooted path, else a path inside the data folder; `:memory:` is no file.
    public string? DatabasePath(string home, Func<string, string?> env)
    {
        if (env(Variable) is not { Length: > 0 } value || value == ":memory:") return null;
        try { return Path.GetFullPath(Path.IsPathRooted(value) ? value : Path.Combine(DataFolder(home, env), value)); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException or SecurityException) { return null; }
    }

    static readonly (string Path, OpenCodeApp App)[] Overrides =
        [.. All.Select(app => (app.DatabasePath(AppPaths.Home, Environment.GetEnvironmentVariable), app)).Where(entry => entry.Item1 is not null)
            .Select(entry => (entry.Item1!, entry.app))];

    /// The app whose database a path is: a `Variable` file, else by file name. Kilo's channel build keeps a pre-existing
    /// `opencode-<channel>.db` in its own folder.
    public static OpenCodeApp? Of(string path)
    {
        foreach (var (file, app) in Overrides)
            if (string.Equals(path, file, StringComparison.OrdinalIgnoreCase)) return app;
        var name = Path.GetFileName(path);
        var match = All.FirstOrDefault(app => name == $"{app.Name}.db"
            || (name.StartsWith($"{app.Name}-", StringComparison.Ordinal) && name.EndsWith(".db", StringComparison.Ordinal)));
        return match?.Name == "opencode" && Path.GetFileName(Path.GetDirectoryName(path)) == "kilo" ? All[1] : match;
    }
}

/// Reads OpenCode sessions from its database, opened read-only (OpenCode writes it in WAL mode).
/// - Two stores: v1 `message` + `part` rows, and v2 `session_message` rows (role in `type`, a step's tools, text and reasoning
///   inside its `content`), with sessions in `session` or, since v2's split, `session_v2`. A database migrated to v2 keeps its
///   v1 tables and copies their sessions under the same ids, so each session is read from the one store whose newest message
///   is newer (v2 on a tie) and never counted twice; a session in both session tables takes the row updated last.
/// - Re-queried when the database, its WAL or the WAL index header in `-shm` changed (every commit rewrites that header,
///   while NTFS may report a file held open with stale times, rule 8), and at least every 2 s while a session is in a turn
///   or updated within the hour. Then only sessions updated within the hour, with an open turn, or whose `time_updated`
///   moved; a message row is fetched again only when its `time_updated` changes. v2 steps leave the session's
///   `time_updated` alone, so sessions with v2 messages changed within the hour count as updated then. A read the database
///   refused (busy) is never cached: that session is queried again on the next read.
/// - v2 rows are read with SQLite's JSON functions, so their text never leaves SQLite; an OS library without them
///   (an older winsqlite3) has the row parsed in memory instead, as v1 bodies are, and nothing but the same fields kept.
/// - A v1 message body over 64 KB is never loaded whole when its first 4 KB name a user message (a summary with file diffs
///   can reach hundreds of MB). Anything else, such as an assistant message holding a provider's error page, is loaded up to
///   16 MB; past that (v2: a row over 16 MB) an assistant message counts as a failed request.
/// - Turn state: an assistant message without `time.completed` is generating (a running tool shows as `tool`, the question
///   tool as `input`); `finish: "tool-calls"` continues the loop; another finish ends the turn (`complete`); an error or no
///   finish at all ends it as `interrupted`. v2 has no parent link: a turn runs from the prompt that opened it (with idle
///   markers, the first prompt after the last one; else the latest), and an idle marker ends it with its outcome.
/// - Speed: per completed assistant message, output + reasoning tokens over the time from `time.created` to its last generated
///   part (text or reasoning end, or a tool's execution start), so a tool's run time is not counted. v2 records no text
///   times: its `time.streamed` when recorded, else the step's end when it ran no tool, else the last tool's execution start
///   when a tool came last. Request processing rate, first-response wait included; nothing is measured when a part could
///   not be read.
public sealed class OpenCodeLog(string path) : ITokenLogReader
{
    public string Path { get; } = path;
    /// "Kilo Code" or "MiMo Code" for those apps' databases; null for OpenCode's.
    public string? ClientName { get; } = OpenCodeApp.Of(path)?.Client;
    long[]? signature;
    DateTimeOffset? lastRead;
    Dictionary<string, OpenCodeSession> sessions = new(StringComparer.Ordinal);

    /// Checks only: read v2 rows as if the SQLite library lacked JSON functions.
    internal static bool AvoidJsonFunctions;

    /// A database `Files` lists: an `OpenCodeApp`'s default or channel file name, or its `<APP>_DB` file.
    public static bool IsDatabase(string path) => OpenCodeApp.Of(path) is not null;

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
            if (OpenCodeSchema.Read(database) is not { } schema) return;
            var listed = new Dictionary<string, OpenCodeListed>(StringComparer.Ordinal);
            void Collect(OpenCodeDatabase.Row row)
            {
                if (row.Text(0) is not { } id || row.Date(5) is not { } updated) return;
                // The first table listed (`session_v2`) wins a tie.
                if (listed.TryGetValue(id, out var known) && known.Updated >= updated) return;
                listed[id] = new(id, row.Text(1), row.Text(2), row.Text(3), row.Text(4), updated, row.Text(7) == "fallback" ? null : row.Text(6));
            }
            foreach (var table in schema.SessionTables)
                if (!database.Query($"SELECT {schema.SessionColumns(table)} WHERE {schema.Unarchived(table)} ORDER BY time_updated DESC LIMIT 64", [], Collect)) return;
            var moved = new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
            if (schema.HasV2)
            {
                var since = now.AddSeconds(-3_600).ToUnixTimeMilliseconds();
                if (!database.Query($"SELECT session_id, MAX(time_updated) FROM session_message WHERE time_created >= {since} GROUP BY session_id", [],
                        row => { if (row.Text(0) is { } id && row.Date(1) is { } updated) moved[id] = updated; })) return;
            }
            var missing = moved.Keys.Union(sessions.Values.Where(session => session.Summary.Open).Select(session => session.Id), StringComparer.Ordinal)
                .Where(id => !listed.ContainsKey(id)).Order(StringComparer.Ordinal).ToList();
            foreach (var id in missing)
                foreach (var table in schema.SessionTables)
                    if (!database.Query($"SELECT {schema.SessionColumns(table)} WHERE id = ? AND {schema.Unarchived(table)}", [id], Collect)) return;
            var ordered = listed.Values
                .Select(row => moved.TryGetValue(row.Id, out var changed) && changed > row.Updated ? row with { Updated = changed } : row)
                .OrderByDescending(row => row.Updated).ThenBy(row => row.Id, StringComparer.Ordinal).ToList();
            var kept = new Dictionary<string, OpenCodeSession>(StringComparer.Ordinal);
            var complete = true;
            for (var offset = 0; offset < ordered.Count; offset++)
            {
                var row = ordered[offset];
                sessions.TryGetValue(row.Id, out var existing);
                if (offset >= 32 && (now - row.Updated).TotalSeconds > 3_600 && existing?.Summary.Open != true) continue;
                var session = existing ?? new OpenCodeSession(row.Id);
                var changedRow = existing is null || session.Updated != row.Updated;
                session.ParentID = row.Parent;
                session.Directory = row.Directory;
                session.Agent = row.Agent;
                session.SessionModel = row.Model is { } model ? ModelID(model) : null;
                session.Title = Title(row.Title);
                session.Updated = row.Updated;
                if ((changedRow || (now - row.Updated).TotalSeconds <= 3_600 || session.Summary.Open) && !Refresh(session, database, schema))
                {
                    // Keeps what was read before; MinValue makes the next read refresh it again.
                    session.Updated = DateTimeOffset.MinValue;
                    complete = false;
                }
                kept[row.Id] = session;
            }
            sessions = kept;
            signature = complete ? current : null;
            lastRead = now;
        }
        finally { database.Execute("COMMIT"); }
    }

    long[]? CurrentSignature() => OpenCodeDatabase.Signature(Path);

    /// False when the database refused a read; the session then keeps its previous messages.
    bool Refresh(OpenCodeSession session, OpenCodeDatabase database, OpenCodeSchema schema)
    {
        var v1 = new List<OpenCodeEntry>();
        var v2 = new List<OpenCodeEntry>();
        if (schema.HasV1 && !database.Query($"SELECT id, time_created, time_updated FROM message WHERE session_id = ?{schema.MainThread} ORDER BY time_created DESC, id DESC LIMIT 200",
                [session.Id], row => { if (row.Text(0) is { } id && row.Date(1) is { } created && row.Date(2) is { } updated) v1.Add(new(id, created, updated, null)); }))
            return false;
        if (schema.HasV2 && !database.Query("SELECT id, time_created, time_updated, type FROM session_message WHERE session_id = ? AND type IN ('user', 'assistant', 'idle') ORDER BY seq DESC LIMIT 200",
                [session.Id], row => { if (row.Text(0) is { } id && row.Date(1) is { } created && row.Date(2) is { } updated) v2.Add(new(id, created, updated, row.Text(3))); }))
            return false;
        var useV2 = v2.Count > 0 && (v1.Count == 0 || v2.Max(entry => entry.Created) >= v1.Max(entry => entry.Created));
        if (session.V2 != useV2)
        {
            session.V2 = useV2;
            session.Cache = new(StringComparer.Ordinal);
            session.Speed = null;
        }
        var json = useV2 && !AvoidJsonFunctions && database.Query("SELECT json_extract('{}', '$.a')", [], _ => { });
        var messages = new List<OpenCodeMessage>(useV2 ? v2.Count : v1.Count);
        foreach (var entry in useV2 ? v2 : v1)
        {
            if (session.Cache.TryGetValue(entry.Id, out var cached) && cached.Updated == entry.Updated)
            {
                messages.Add(cached);
                continue;
            }
            if ((useV2 ? V2Message(entry, database, json) : Message(entry.Id, entry.Created, entry.Updated, database)) is not { } message) return false;
            messages.Add(message);
        }
        session.Cache = messages.GroupBy(message => message.Id, StringComparer.Ordinal).ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);
        session.Messages = useV2 ? LinkTurns(messages) : messages;

        List<OpenCodePart>? PartsOf(OpenCodeMessage message) => useV2 ? V2Parts(message, database, json) : Parts(message.Id, database);
        session.OpenParts = session.Messages.FirstOrDefault() is { Role: OpenCodeRole.Assistant, Completed: null } open ? PartsOf(open) : null;
        if (session.Messages.FirstOrDefault(message => message is { Role: OpenCodeRole.Assistant, Completed: not null, Failed: false, Generated: > 0 }) is { } measured)
        {
            if (session.Speed is not { } speed || speed.MessageID != measured.Id || speed.Updated != measured.Updated)
                session.Speed = (measured.Id, measured.Updated, PartsOf(measured) is { } parts ? useV2 ? V2Measurement(measured, parts) : Measurement(measured, parts) : null);
        }
        else session.Speed = null;
        session.Summary = OpenCodeSummary.Of(session);
        return true;
    }

    /// One message's metadata; null when the database refused the read or the row changed under it.
    static OpenCodeMessage? Message(string id, DateTimeOffset created, DateTimeOffset updated, OpenCodeDatabase database)
    {
        string? body = null;
        long? rowid = null;
        if (!database.Query($"SELECT CASE WHEN {database.SizeOfData} <= 65536 THEN data END, rowid FROM message WHERE id = ?", [id],
                row => { body = row.Text(0); rowid = row.Int64(1); }) || rowid is not { } found) return null;
        if (body is not null) return OpenCodeMessage.Parse(id, created, updated, body);
        if (database.MessageHead(found) is not { } head) return null;
        var role = OpenCodeMessage.RoleInHead(head);
        if (role == OpenCodeRole.User) return new(id, created, updated) { Role = OpenCodeRole.User };
        string? full = null;
        if (!database.Query($"SELECT CASE WHEN {database.SizeOfData} <= 16777216 THEN data END FROM message WHERE id = ?", [id],
                result => full = result.Text(0))) return null;
        if (full is not null) return OpenCodeMessage.Parse(id, created, updated, full);
        return role == OpenCodeRole.Assistant ? new(id, created, updated) { Role = role, Failed = true, Completed = updated } : new(id, created, updated);
    }

    const string V2Fields = """
        json_extract(data, '$.time.completed'), json_extract(data, '$.time.streamed'), json_extract(data, '$.finish'),
        coalesce(json_type(data, '$.error'), 'null') != 'null', json_extract(data, '$.model.id'), json_extract(data, '$.agent'),
        json_extract(data, '$.tokens.output'), json_extract(data, '$.tokens.reasoning'), json_extract(data, '$.tokens.input'),
        json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cache.write'), json_extract(data, '$.outcome'),
        coalesce(json_type(data, '$.retry'), 'null') != 'null'
        """;

    /// A v2 row's metadata (through SQLite's JSON functions when `json`); a prompt's row is never read. Null when the
    /// database refused the read.
    static OpenCodeMessage? V2Message(OpenCodeEntry entry, OpenCodeDatabase database, bool json)
    {
        var role = entry.Type switch { "user" => OpenCodeRole.User, "assistant" => OpenCodeRole.Assistant, "idle" => OpenCodeRole.Idle, _ => OpenCodeRole.Other };
        var message = new OpenCodeMessage(entry.Id, entry.Created, entry.Updated) { Role = role };
        if (role is not (OpenCodeRole.Assistant or OpenCodeRole.Idle)) return message;
        OpenCodeMessage? read = null;
        if (json)
        {
            if (!database.Query($"SELECT {V2Fields} FROM session_message WHERE id = ? AND {database.SizeOfData} <= 16777216 AND json_valid(data)", [entry.Id],
                    row => read = message with
                    {
                        Completed = Milliseconds(row.Double(0)),
                        Streamed = Milliseconds(row.Double(1)),
                        Finish = Short(row.Text(2)),
                        Failed = row.Int64(3) == 1,
                        Model = Short(row.Text(4)),
                        Agent = Short(row.Text(5)),
                        Generated = LogFields.Add(Count(row.Double(6)), Count(row.Double(7))),
                        Context = LogFields.Add(LogFields.Add(Count(row.Double(8)), Count(row.Double(9))), Count(row.Double(10))),
                        Outcome = Short(row.Text(11)),
                        Retried = row.Int64(12) == 1,
                    })) return null;
        }
        else
        {
            string? body = null;
            if (!database.Query($"SELECT CASE WHEN {database.SizeOfData} <= 16777216 THEN data END FROM session_message WHERE id = ?", [entry.Id],
                    row => body = row.Text(0))) return null;
            if (body is not null) read = OpenCodeMessage.ParseV2(message, body);
        }
        return read ?? (role == OpenCodeRole.Assistant ? message with { Failed = true, Completed = entry.Updated } : message);
    }

    /// v2 rows name no parent: a prompt opens a turn when none is open (idle markers close one; without them every prompt
    /// opens its own), and the turn's messages point at it, as v1's `parentID` does. `messages` is newest first.
    static List<OpenCodeMessage> LinkTurns(List<OpenCodeMessage> messages)
    {
        var marked = messages.Any(message => message.Role == OpenCodeRole.Idle);
        var linked = new OpenCodeMessage[messages.Count];
        string? opener = null;
        for (var index = messages.Count - 1; index >= 0; index--)
        {
            var message = messages[index];
            switch (message.Role)
            {
                case OpenCodeRole.User:
                    if (opener is null || !marked) opener = message.Id;
                    message = message with { ParentID = opener };
                    break;
                case OpenCodeRole.Assistant: message = message with { ParentID = opener }; break;
                case OpenCodeRole.Idle: opener = null; break;
            }
            linked[index] = message;
        }
        return [.. linked];
    }

    static List<OpenCodePart>? Parts(string message, OpenCodeDatabase database)
    {
        var parts = new List<OpenCodePart>();
        return database.Query("SELECT time_updated, CASE WHEN " + database.SizeOfData + " <= 262144 THEN data END FROM part WHERE message_id = ? ORDER BY id",
            [message], row => { if (row.Date(0) is { } updated) parts.Add(OpenCodePart.Parse(updated, row.Text(1))); }) ? parts : null;
    }

    /// A v2 step's `content` items, in order: type, tool name and status, a tool's execution start and a reasoning end.
    static List<OpenCodePart>? V2Parts(OpenCodeMessage message, OpenCodeDatabase database, bool json)
    {
        var parts = new List<OpenCodePart>();
        if (json)
            return database.Query($"""
                SELECT json_extract(value, '$.type'), json_extract(value, '$.name'), json_extract(value, '$.state.status'),
                       json_extract(value, '$.time.ran'), json_extract(value, '$.time.completed')
                FROM session_message, json_each(session_message.data, '$.content')
                WHERE session_message.id = ? AND {database.SizeOfData} <= 16777216 AND json_valid(session_message.data)
                ORDER BY json_each.key
                """, [message.Id], row => parts.Add(new(message.Updated, true, Short(row.Text(0)), Short(row.Text(1)), Short(row.Text(2)),
                    Milliseconds(row.Double(3)), Milliseconds(row.Double(4))))) ? parts : null;
        string? body = null;
        if (!database.Query($"SELECT CASE WHEN {database.SizeOfData} <= 16777216 THEN data END FROM session_message WHERE id = ?", [message.Id],
                row => body = row.Text(0))) return null;
        return body is null ? parts : OpenCodePart.ParseV2Content(message.Updated, body);
    }

    /// Output + reasoning over created → last generated part; null when a part was unreadable or no time was recorded.
    static TokenSpeedMeasurement? Measurement(OpenCodeMessage message, List<OpenCodePart> parts)
    {
        if (parts.Any(part => !part.Readable)) return null;
        var ends = parts.Select(part => part.Type switch
        {
            "text" or "reasoning" => part.End ?? part.Updated,
            "tool" => part.ToolStart,
            _ => (DateTimeOffset?)null,
        }).OfType<DateTimeOffset>().ToList();
        return Speed(message, ends.Count == 0 ? null : ends.Max(), parts.Any(part => part.Type == "retry"));
    }

    /// v2: output + reasoning over created → the stream's recorded end; else the step's end when it ran no tool; else the
    /// last tool's execution start (or a reasoning end) when a tool came last. Text carries no time.
    static TokenSpeedMeasurement? V2Measurement(OpenCodeMessage message, List<OpenCodePart> parts)
    {
        DateTimeOffset? end = null;
        if (message.Streamed is { } streamed) end = streamed;
        else if (!parts.Any(part => part.Type == "tool")) end = message.Completed;
        else if (parts[^1].Type == "tool")
            end = parts.Select(part => part.Type switch { "tool" => part.ToolStart, "reasoning" => part.End, _ => null }).OfType<DateTimeOffset>()
                .Select(at => (DateTimeOffset?)at).Max();
        return Speed(message, end, message.Retried);
    }

    static TokenSpeedMeasurement? Speed(OpenCodeMessage message, DateTimeOffset? end, bool retried)
    {
        if (message.Completed is not { } completed || end is not { } last) return null;
        var milliseconds = (last - message.Created).TotalMilliseconds;
        if (!double.IsFinite(milliseconds) || milliseconds <= 0) return null;
        return new TokenSpeedMeasurement(new TelemetryReading
        {
            Provider = TokenSource.OpenCode,
            At = completed,
            Model = message.Model,
            OutputTokens = message.Generated,
            RequestDurationMs = Math.Round(milliseconds),
            RequestDurationIncludesRetries = retried,
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
                ClientName = ClientName,
                SessionID = session.Id,
                Title = session.Title,
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

    /// `session.title` once generated or renamed; OpenCode's placeholder ("New session - <ISO time>", "Child session - …",
    /// its `isDefaultTitle`) is no title, nor is a title MiMo Code marks `title_source = 'fallback'` (dropped when listed).
    public static string? Title(string? raw) =>
        raw is null || Placeholder.IsMatch(raw) ? null : SessionTitle.Clean(raw);

    static readonly Regex Placeholder =
        new(@"^(New session - |Child session - )[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$", RegexOptions.CultureInvariant);

    static string? ModelID(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > 4_096) return null;
        try
        {
            using var document = JsonDocument.Parse(json, Json.Depth);
            return Short(document.RootElement.Field("id")) ?? Short(document.RootElement.Field("modelID"));
        }
        catch (JsonException) { return null; }
    }

    internal static string? Short(JsonElement? value) => Short(value?.Text);

    internal static string? Short(string? text) => text is { Length: > 0 and <= 256 } ? text : null;

    internal static DateTimeOffset? Milliseconds(JsonElement? value) => Milliseconds(value?.Number);

    internal static DateTimeOffset? Milliseconds(double? number) =>
        number is { } value && value > 0 && value < 253_402_300_800_000 ? DateTimeOffset.FromUnixTimeMilliseconds((long)value) : null;

    internal static int Count(JsonElement? value) => Count(value?.Number);

    internal static int Count(double? number) => number is { } value && double.IsFinite(value) && value > 0 ? (int)Math.Min(value, int.MaxValue) : 0;
}

/// The schema a pass reads, from `PRAGMA table_info`: which session tables and message stores exist, and the columns that
/// differ between OpenCode's versions and the apps built on it.
sealed class OpenCodeSchema
{
    readonly Dictionary<string, HashSet<string>> columns = new(StringComparer.Ordinal);

    /// Null when the database refused the read.
    public static OpenCodeSchema? Read(OpenCodeDatabase database)
    {
        var schema = new OpenCodeSchema();
        foreach (var table in new[] { "session_v2", "session", "message", "part", "session_message" })
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            if (!database.Query($"PRAGMA table_info({table})", [], row => { if (row.Text(1) is { } name) names.Add(name); })) return null;
            if (names.Count > 0) schema.columns[table] = names;
        }
        return schema;
    }

    bool Has(string table, string column) => columns.TryGetValue(table, out var names) && names.Contains(column);

    /// `session_v2` first: a database migrated to v2 keeps the v1 `session` table beside it.
    public IEnumerable<string> SessionTables => new[] { "session_v2", "session" }.Where(table => Has(table, "id") && Has(table, "time_updated"));
    public bool HasV1 => columns.ContainsKey("message") && columns.ContainsKey("part");
    public bool HasV2 => columns.ContainsKey("session_message");
    /// MiMo Code keeps its in-session subagent threads beside the main one (`agent_id`); only the main thread is read.
    public string MainThread => Has("message", "agent_id") ? " AND agent_id = 'main'" : "";

    /// id, parent, directory, agent, model, updated, title (bounded: a generated or renamed one is short), title source.
    public string SessionColumns(string table)
    {
        string Column(string name, string? expression = null) => Has(table, name) ? expression ?? name : "NULL";
        return $"id, {Column("parent_id")}, {Column("directory")}, {Column("agent")}, {Column("model")}, time_updated, "
            + $"{Column("title", "substr(title, 1, 1024)")}, {Column("title_source")} FROM {table}";
    }

    /// Older schemas lack `time_archived`.
    public string Unarchived(string table) => Has(table, "time_archived") ? "time_archived IS NULL" : "1";
}

sealed record OpenCodeListed(string Id, string? Parent, string? Directory, string? Agent, string? Model, DateTimeOffset Updated, string? Title);

/// A message row before its body is read; `Type` is v2's role column.
sealed record OpenCodeEntry(string Id, DateTimeOffset Created, DateTimeOffset Updated, string? Type);

/// `Idle`: v2's marker that a turn ended, with its outcome.
enum OpenCodeRole { User, Assistant, Idle, Other }

/// One message's metadata; never its text.
sealed record OpenCodeMessage(string Id, DateTimeOffset Created, DateTimeOffset Updated)
{
    public OpenCodeRole Role { get; init; } = OpenCodeRole.Other;
    public DateTimeOffset? Completed { get; init; }
    /// v2: when the provider's response ended, before tools settled.
    public DateTimeOffset? Streamed { get; init; }
    public string? Finish { get; init; }
    public bool Failed { get; init; }
    /// v2: the step was retried (its duration then includes the retries).
    public bool Retried { get; init; }
    /// v2 idle marker: succeeded, failed or interrupted.
    public string? Outcome { get; init; }
    public string? Model { get; init; }
    /// The prompt that opened the turn (v2: set by `LinkTurns`).
    public string? ParentID { get; init; }
    public string? Cwd { get; init; }
    public string? Agent { get; init; }
    /// Output + reasoning tokens (OpenCode records them apart).
    public int Generated { get; init; }
    /// Input + cache read + cache write of this request.
    public int Context { get; init; }

    public static OpenCodeMessage Parse(string id, DateTimeOffset created, DateTimeOffset updated, string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body, Json.Depth);
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
                Generated = LogFields.Add(OpenCodeLog.Count(tokens?.Field("output")), OpenCodeLog.Count(tokens?.Field("reasoning"))),
                Context = LogFields.Add(LogFields.Add(OpenCodeLog.Count(tokens?.Field("input")), OpenCodeLog.Count(cache?.Field("read"))),
                    OpenCodeLog.Count(cache?.Field("write"))),
            };
        }
        catch (JsonException) { return new(id, created, updated); }
    }

    /// A v2 row parsed in memory (no SQLite JSON functions): the fields `OpenCodeLog.V2Fields` selects; null when invalid.
    public static OpenCodeMessage? ParseV2(OpenCodeMessage message, string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body, Json.Depth);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var time = root.Field("time");
            var tokens = root.Field("tokens");
            var cache = tokens?.Field("cache");
            return message with
            {
                Completed = OpenCodeLog.Milliseconds(time?.Field("completed")),
                Streamed = OpenCodeLog.Milliseconds(time?.Field("streamed")),
                Finish = OpenCodeLog.Short(root.Field("finish")),
                Failed = root.Field("error") is { ValueKind: not JsonValueKind.Null },
                Model = OpenCodeLog.Short(root.Field("model")?.Field("id")),
                Agent = OpenCodeLog.Short(root.Field("agent")),
                Generated = LogFields.Add(OpenCodeLog.Count(tokens?.Field("output")), OpenCodeLog.Count(tokens?.Field("reasoning"))),
                Context = LogFields.Add(LogFields.Add(OpenCodeLog.Count(tokens?.Field("input")), OpenCodeLog.Count(cache?.Field("read"))),
                    OpenCodeLog.Count(cache?.Field("write"))),
                Outcome = OpenCodeLog.Short(root.Field("outcome")),
                Retried = root.Field("retry") is { ValueKind: not JsonValueKind.Null },
            };
        }
        catch (JsonException) { return null; }
    }

    /// The role from the first bytes of a message body. OpenCode writes `role` among the first keys, and any `"role"` in
    /// text would be escaped (`\"role\"`), so the first unescaped one is the message's own.
    public static OpenCodeRole RoleInHead(byte[] head)
    {
        var text = Encoding.UTF8.GetString(head);
        var key = text.IndexOf("\"role\"", StringComparison.Ordinal);
        if (key < 0) return OpenCodeRole.Other;
        var rest = text.AsSpan(key + 6).TrimStart(" :");
        return rest.StartsWith("\"user\"", StringComparison.Ordinal) ? OpenCodeRole.User
            : rest.StartsWith("\"assistant\"", StringComparison.Ordinal) ? OpenCodeRole.Assistant : OpenCodeRole.Other;
    }
}

/// One part's type, tool name and state, and its times; never its text, input or output. A v2 `content` item carries no
/// time of its own, so `Updated` is its message's.
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

    /// A v2 row's `content` items parsed in memory (no SQLite JSON functions); empty when the row is invalid.
    public static List<OpenCodePart> ParseV2Content(DateTimeOffset updated, string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body, Json.Depth);
            if (document.RootElement.Field("content") is not { ValueKind: JsonValueKind.Array } content) return [];
            return [.. content.EnumerateArray().Select(item => new OpenCodePart(updated, true, OpenCodeLog.Short(item.Field("type")),
                OpenCodeLog.Short(item.Field("name")), OpenCodeLog.Short(item.Field("state")?.Field("status")),
                OpenCodeLog.Milliseconds(item.Field("time")?.Field("ran")), OpenCodeLog.Milliseconds(item.Field("time")?.Field("completed"))))];
        }
        catch (JsonException) { return []; }
    }
}

sealed class OpenCodeSession(string id)
{
    public string Id { get; } = id;
    public string? ParentID { get; set; }
    public string? Directory { get; set; }
    public string? Agent { get; set; }
    public string? SessionModel { get; set; }
    public string? Title { get; set; }
    public DateTimeOffset Updated { get; set; } = DateTimeOffset.MinValue;
    /// Whether its messages are read from the v2 store; switching stores drops the cache.
    public bool V2 { get; set; }
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
                ? (opener.Created, assistants.Where(message => message.ParentID == user).Aggregate(0, (sum, message) => LogFields.Add(sum, message.Generated))) : null;

        var open = false;
        var state = TokenActivityState.Idle;
        string? toolName = null;
        var waits = false;
        DateTimeOffset? startedAt = null;
        int? turnOutput = null;
        switch (newest.Role)
        {
            case OpenCodeRole.User:
                // A v2 prompt sent while a turn runs joins it.
                var joined = Turn(newest.ParentID ?? newest.Id);
                (open, state, startedAt, turnOutput) = (true, TokenActivityState.Working, joined?.Start ?? newest.Created, joined?.Output ?? 0);
                break;
            case OpenCodeRole.Assistant:
                if (newest.Completed is null)
                {
                    (open, state) = (true, TokenActivityState.Working);
                    // v1 tools are pending or running; v2's are streaming (dev builds: pending) or running.
                    var running = parts.Where(part => part.Type == "tool" && part.Status is "pending" or "streaming" or "running").ToList();
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
            case OpenCodeRole.Idle:
                state = newest.Outcome switch { "succeeded" => TokenActivityState.Complete, null => TokenActivityState.Idle, _ => TokenActivityState.Interrupted };
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

/// A connection to an SQLite database (OpenCode's; omp's and Pi's usage history) through the OS library: winsqlite3.dll
/// (Windows 10+); on a mac or Linux host (checks) the system libsqlite3. Opened read-only; `create` is for check fixtures.
sealed class OpenCodeDatabase : IDisposable
{
    const string Library = "winsqlite3";
    const int Ok = 0, RowReady = 100, Done = 101, Integer = 1, Float = 2, Null = 5;
    const int OpenReadOnly = 0x1, OpenReadWrite = 0x2, OpenCreate = 0x4, OpenUri = 0x40, OpenNoMutex = 0x8000;
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

    /// `immutable` opens the file as a snapshot (`?immutable=1`): for a WAL database whose writer quit and removed its
    /// `-wal`/`-shm`, which a read-only connection cannot recreate. Later writes are not seen, so reopen on a changed stamp.
    public static OpenCodeDatabase? Open(string path, bool create = false, bool immutable = false)
    {
        try
        {
            var flags = (create ? OpenReadWrite | OpenCreate : OpenReadOnly) | OpenNoMutex | (immutable ? OpenUri : 0);
            var status = sqlite3_open_v2(Utf8(immutable ? ImmutableUri(path) : path), out var handle, flags, IntPtr.Zero);
            if (status == Ok && handle != IntPtr.Zero) return new OpenCodeDatabase(handle);
            if (handle != IntPtr.Zero) sqlite3_close_v2(handle);
            return null;
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException) { return null; }
    }

    /// `file:` URI of a path (`%`, `?` and `#` escaped; a drive path as `file:///C:/…`) with `immutable=1`.
    static string ImmutableUri(string path)
    {
        var escaped = string.Concat(path.Replace('\\', '/').Select(c => c is '%' or '?' or '#' ? $"%{(int)c:X2}" : c.ToString()));
        return (escaped.StartsWith('/') ? "file://" : "file:///") + escaped + "?immutable=1";
    }

    /// Database identity, size and write time, the WAL's size and write time, and the WAL index header (the first 48 bytes
    /// of `-shm`, whose change counter and frame count move on every commit). Null when the database is missing.
    public static long[]? Signature(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) return null;
        var wal = new FileInfo(path + "-wal");
        var header = new byte[48];
        try
        {
            using var shm = new FileStream(path + "-shm", FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, bufferSize: 0);
            shm.ReadAtLeast(header, header.Length, throwOnEndOfStream: false);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return [info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks,
                wal.Exists ? wal.Length : -1, wal.Exists ? wal.LastWriteTimeUtc.Ticks : -1,
                .. Enumerable.Range(0, 6).Select(index => BitConverter.ToInt64(header, index * 8))];
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

        public long? Int64(int column) => sqlite3_column_type(statement, column) == Integer ? sqlite3_column_int64(statement, column) : null;

        /// REAL or INTEGER as a number; null for NULL or text.
        public double? Double(int column) =>
            sqlite3_column_type(statement, column) is Float or Integer ? sqlite3_column_double(statement, column) : null;
    }

    /// The first `count` bytes of a message's `data`, read in place (incremental blob I/O), so a body of hundreds of MB is
    /// never loaded; null when the row cannot be opened.
    public byte[]? MessageHead(long rowid, int count = 4_096)
    {
        if (sqlite3_blob_open(handle, Utf8("main"), Utf8("message"), Utf8("data"), rowid, 0, out var blob) != Ok || blob == IntPtr.Zero)
        {
            if (blob != IntPtr.Zero) sqlite3_blob_close(blob);
            return null;
        }
        try
        {
            var head = new byte[Math.Min(count, sqlite3_blob_bytes(blob))];
            return sqlite3_blob_read(blob, head, head.Length, 0) == Ok ? head : null;
        }
        finally { sqlite3_blob_close(blob); }
    }

    static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value + "\0");

    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_blob_open(IntPtr database, byte[] schema, byte[] table, byte[] column, long row, int flags, out IntPtr blob);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_blob_bytes(IntPtr blob);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_blob_read(IntPtr blob, byte[] buffer, int count, int offset);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_blob_close(IntPtr blob);

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
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern double sqlite3_column_double(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.Winapi)] static extern int sqlite3_column_bytes(IntPtr statement, int column);
}
