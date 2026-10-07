namespace TokenCat;

// Goose's SQLite store; mirrors the mac's Providers/GooseLog.swift. Only roles, times, visibility, block types, tool names and
// ids, per-call token counts and durations, model, cwd and a generated or person-set title are read; JSON columns go through
// json_extract/json_each, so message text, tool arguments and results never leave SQLite.

public sealed partial record TokenLogFormat
{
    /// Goose's `sessions.db` in each data folder's `sessions` (the roots); one reader covers every session in it.
    public static readonly TokenLogFormat Goose = new(
        (roots, discovery) => discovery.Recent(roots.Select(root => new FileInfo(Path.Combine(root, GooseLog.DatabaseName))).Where(file => file.Exists)),
        GooseLog.IsDatabase, path => new GooseLog(path));
}

/// Reads Goose sessions from its SQLite store (crates/goose/src/session/session_manager.rs, schema 16), opened read-only
/// (Goose writes it in WAL mode).
/// - Re-queried when the database, its WAL or the WAL index header in `-shm` changed, and at least every 2 s while a session
///   is in a turn or updated within the hour (NTFS may report a file held open with stale times, rule 8). Then the 64 newest
///   sessions by `updated_at`, refreshing those whose `updated_at` moved, with an open turn, or updated within two minutes
///   (`updated_at` has whole seconds). Message content blocks are parsed once per message row; a read the database refused
///   (busy) is never cached.
/// - Turn state, as Goose's own `pending_tool_confirmations`: the turn opens at the newest user-visible user message that is no
///   tool response. A tool confirmation or MCP elicitation without its answer waits for the person (`Input`); a tool request
///   without its `toolResponse` runs (`Tool`); tool results or a fresh prompt are `Working`; an assistant reply without tool
///   requests ends the turn (`Complete`), an error block (or credits running out) as `Interrupted`.
/// - Tokens: `usage_ledger` rows (one per model call, whole-second `created_timestamp`); the backfilled `carried_forward` rows
///   are no call and are skipped. A turn's output is the rows from its prompt to the next one.
/// - Speed: the newest assistant message's own `metadata.usage` — output tokens over `elapsedMs`, the request time Goose's
///   stream wrapper measured (first-token wait included, `timeToFirstTokenMs` kept). Nothing is measured without it.
/// - A session on a CLI or ACP agent provider (claude-code, codex, gemini-cli, cursor-agent, `*-acp`) reports no output or
///   speed: that agent writes its own log, which TokenCat already counts. Its state, tool, model and context still show.
public sealed class GooseLog(string path) : ITokenLogReader
{
    public const string DatabaseName = "sessions.db";
    public string Path { get; } = path;
    long[]? signature;
    DateTimeOffset? lastRead;
    Dictionary<string, GooseSession> sessions = new(StringComparer.Ordinal);

    public static bool IsDatabase(string path) => System.IO.Path.GetFileName(path) == DatabaseName;

    // Reading

    public void Read(int tailLimit, DateTimeOffset now)
    {
        if (OpenCodeDatabase.Signature(Path) is not { } current) return;
        var hot = sessions.Values.Any(session => session.Summary.Open || (now - session.Updated).TotalSeconds <= 3_600);
        if (signature is not null && current.SequenceEqual(signature) && !(hot && lastRead is { } last && (now - last).TotalSeconds >= 2)) return;
        using var database = OpenCodeDatabase.Open(Path);
        if (database is null || !database.Execute("BEGIN")) return;
        try
        {
            // Older Goose versions lack later columns (name v3 … parent_session_id v15) and the ledger (v15).
            if (Columns("sessions", database) is not { } columns || !columns.Contains("id") || Columns("messages", database) is not { } messageColumns) return;
            var hasLedger = false;
            if (!database.Query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_ledger'", [], _ => hasLedger = true)) return;
            string Column(string name, string? expression = null) => columns.Contains(name) ? expression ?? name : "NULL";
            const string config = "CASE WHEN json_valid(model_config_json) THEN model_config_json END";
            var sql = $"""
                SELECT id, {Column("working_dir")}, substr({Column("name")}, 1, 1024), substr({Column("description")}, 1, 1024),
                       {Column("user_set_name")}, {Column("session_type")},
                       CAST(strftime('%s', COALESCE(updated_at, created_at)) AS INTEGER), {Column("provider_name")},
                       {Column("model_config_json", $"json_extract({config}, '$.model_name')")},
                       {Column("model_config_json", $"json_extract({config}, '$.context_limit')")},
                       {Column("parent_session_id")}, {Column("recipe_json", "recipe_json IS NOT NULL AND recipe_json != ''")}
                FROM sessions {(columns.Contains("archived_at") ? "WHERE archived_at IS NULL" : "")} ORDER BY 7 DESC LIMIT 64
                """;
            var listed = new List<GooseListed>();
            if (!database.Query(sql, [], row =>
                {
                    if (row.Text(0) is not { } id || Seconds(row.Int64(6)) is not { } updated) return;
                    var name = row.Text(2) is { Length: > 0 } given ? given : row.Text(3);
                    listed.Add(new(id, row.Text(1), Title(name, row.Int64(4) == 1, row.Text(7), row.Int64(11) == 1), updated, Short(row.Text(8)),
                        row.Int64(9) is > 0 and var limit ? (int)Math.Min(limit, int.MaxValue) : null, Short(row.Text(10)),
                        row.Text(7) is { } provider && IsAgentProvider(provider)));
                })) return;
            var kept = new Dictionary<string, GooseSession>(StringComparer.Ordinal);
            var complete = true;
            for (var offset = 0; offset < listed.Count; offset++)
            {
                var row = listed[offset];
                sessions.TryGetValue(row.Id, out var existing);
                if (offset >= 32 && (now - row.Updated).TotalSeconds > 3_600 && existing?.Summary.Open != true) continue;
                var session = existing ?? new GooseSession(row.Id);
                var moved = existing is null || session.Updated != row.Updated;
                session.Directory = row.Directory;
                session.Title = row.Title;
                session.SessionModel = row.Model;
                session.ContextLimit = row.ContextLimit;
                session.ParentID = row.ParentID;
                session.AgentProvider = row.AgentProvider;
                session.Updated = row.Updated;
                // A session idle for over an hour reads a shorter window: its last turns, not 200 messages of content.
                var window = session.Summary.Open || (now - row.Updated).TotalSeconds <= 3_600 ? 200 : 50;
                if ((moved || session.Summary.Open || (now - row.Updated).TotalSeconds <= 120)
                    && !Refresh(session, database, window, messageColumns.Contains("metadata_json"), hasLedger))
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

    static HashSet<string>? Columns(string table, OpenCodeDatabase database)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        return database.Query($"SELECT name FROM pragma_table_info('{table}')", [], row => { if (row.Text(0) is { } name) names.Add(name); }) ? names : null;
    }

    /// False when the database refused a read; the session then keeps its previous messages.
    static bool Refresh(GooseSession session, OpenCodeDatabase database, int window, bool metadata, bool ledger)
    {
        // Goose orders messages by (created_timestamp, id); seconds, or milliseconds in some imported rows.
        const string created = "CASE WHEN created_timestamp > 10000000000 THEN created_timestamp / 1000 ELSE created_timestamp END";
        var messages = new List<GooseMessage>();
        if (!database.Query($"""
                SELECT id, role, {created}, CAST(strftime('%s', timestamp) AS INTEGER), json_extract(md, '$.userVisible'),
                       json_extract(md, '$.usage.outputTokens'), json_extract(md, '$.usage.elapsedMs'),
                       json_extract(md, '$.usage.timeToFirstTokenMs'), json_extract(md, '$.inference.resolvedModel'),
                       json_extract(md, '$.inference.requestedModel')
                FROM (SELECT id, role, created_timestamp, timestamp, {(metadata ? "CASE WHEN json_valid(metadata_json) THEN metadata_json END" : "NULL")} AS md
                      FROM messages WHERE session_id = ? ORDER BY created_timestamp DESC, id DESC LIMIT {window})
                """, [session.Id], row =>
                {
                    if (row.Int64(0) is not { } id || Seconds(row.Int64(2)) is not { } at) return;
                    messages.Add(new GooseMessage(id, at)
                    {
                        Role = row.Text(1) switch { "user" => GooseRole.User, "assistant" => GooseRole.Assistant, _ => GooseRole.Other },
                        Written = Seconds(row.Int64(3)),
                        Visible = row.Int64(4) != 0,
                        Output = Count(row.Int64(5)),
                        ElapsedMs = row.Double(6) is { } elapsed && double.IsFinite(elapsed) && elapsed > 0 ? elapsed : null,
                        TtftMs = row.Double(7) is { } ttft && double.IsFinite(ttft) && ttft >= 0 ? ttft : null,
                        Model = Short(row.Text(8)) ?? Short(row.Text(9)),
                    });
                })) return false;

        var missing = messages.Select(message => message.Id).Where(id => !session.Blocks.ContainsKey(id)).ToList();
        if (missing.Count > 0)
        {
            var fetched = missing.ToDictionary(id => id, _ => new List<GooseBlock>());
            // Only each block's type, ids, tool names and notification kind; `j.type = 'object'` keeps json_extract off bare values.
            if (!database.Query($"""
                    SELECT m.id, json_extract(j.value, '$.type'), json_extract(j.value, '$.id'),
                           json_extract(j.value, '$.toolCall.value.name'), json_extract(j.value, '$.toolName'),
                           json_extract(j.value, '$.data.actionType'), json_extract(j.value, '$.data.id'),
                           json_extract(j.value, '$.data.toolName'), json_extract(j.value, '$.notificationType')
                    FROM messages m, json_each(CASE WHEN json_valid(m.content_json) THEN m.content_json ELSE '[]' END) j
                    WHERE m.id IN ({string.Join(",", missing)}) AND j.type = 'object' ORDER BY m.id, j.key
                    """, [], row =>
                    {
                        if (row.Int64(0) is not { } id) return;
                        if (!fetched.TryGetValue(id, out var list)) fetched[id] = list = [];
                        list.Add(new GooseBlock(Short(row.Text(1)), Short(row.Text(2)), Short(row.Text(3)) ?? Short(row.Text(4)),
                            Short(row.Text(5)), Short(row.Text(6)), Short(row.Text(7)), Short(row.Text(8))));
                    })) return false;
            foreach (var (id, list) in fetched) session.Blocks[id] = list;
        }
        var ids = messages.Select(message => message.Id).ToHashSet();
        foreach (var stale in session.Blocks.Keys.Where(id => !ids.Contains(id)).ToList()) session.Blocks.Remove(stale);
        session.Messages = [.. messages.Select(message => message with { Blocks = session.Blocks[message.Id] })];

        var usage = new List<GooseUsage>();
        if (ledger && !database.Query($"""
                SELECT {created}, output_tokens, input_tokens, model, is_compaction FROM usage_ledger
                WHERE session_id = ? AND COALESCE(cost_source, '') != 'carried_forward' ORDER BY id DESC LIMIT 200
                """, [session.Id], row =>
                {
                    if (Seconds(row.Int64(0)) is { } at)
                        usage.Add(new(at, Count(row.Int64(1)), Count(row.Int64(2)), Short(row.Text(3)), (row.Int64(4) ?? 0) != 0));
                })) return false;
        session.Usage = usage;
        session.Summary = GooseSummary.Of(session);
        return true;
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
            var newest = new[] { summary.LastLogAt ?? activity, session.Updated, activity }.Max();
            var liveAt = newest < ceiling ? newest : ceiling;
            var age = (now - liveAt).TotalSeconds;
            var horizon = summary.WaitsForInput ? 86_400 : summary.ToolName is not null ? 900 : 600;
            var active = summary.Open && age is >= -5 && age <= horizon;
            var state = !summary.Open ? summary.State
                : summary.WaitsForInput ? active ? TokenActivityState.Input : TokenActivityState.Unfinished
                : active ? summary.State
                : age <= 1_800 ? TokenActivityState.Stale : TokenActivityState.Unfinished;
            var cwd = session.Directory is { Length: > 0 } and not "." ? session.Directory : null;
            var tool = summary.Open ? summary.ToolName : null;
            readings.Add(new TokenReading(TokenSource.Goose, $"{id}#{session.Id}")
            {
                SessionID = session.Id,
                Title = session.Title,
                IsSubagent = session.ParentID is not null,
                ParentSessionID = session.ParentID,
                AgentID = session.ParentID is not null ? session.Id : null,
                Project = cwd is null ? null : ProjectName(cwd),
                ProjectPath = cwd,
                Model = summary.Model ?? session.SessionModel,
                Context = summary.Context is { } context ? context with { WindowTokens = session.ContextLimit } : null,
                LastActivity = lastActivity,
                LastLogAt = liveAt,
                MeasurementAt = summary.Completion?.At ?? lastActivity,
                Active = active,
                ActivityState = state,
                ToolName = tool,
                ToolCategory = tool is null ? null : Category(tool),
                CurrentTurnStartedAt = summary.Open ? summary.StartedAt : null,
                // A CLI or ACP agent provider logs its own tokens (Claude Code, Codex, …), which TokenCat already counts there.
                CurrentTurnOutputTokens = summary.Open && !session.AgentProvider ? summary.TurnOutput : null,
                LastOutputAt = summary.Outputs.Count > 0 && !session.AgentProvider ? summary.Outputs[^1].At : null,
                LastOutputDelta = summary.Outputs.Count > 0 && !session.AgentProvider ? summary.Outputs[^1].Tokens : null,
                RecentOutputs = session.AgentProvider ? []
                    : [.. summary.Outputs.Where(e => (now - e.At).TotalSeconds is >= -5 and <= TokenTracker.RecentOutputWindow)],
                LastOutputTokens = session.AgentProvider ? null : summary.Completion?.Output,
                SpeedMeasurement = session.AgentProvider ? null : summary.Speed,
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

    /// Goose names an extension's tools `<extension>__<tool>`; the developer and summon extensions' are unprefixed (`shell`,
    /// `write`, `edit`, `tree`, `delegate`), older builds wrote `developer__shell`, `developer__text_editor`.
    public static ToolCategory Category(string name)
    {
        var split = name.IndexOf("__", StringComparison.Ordinal);
        var owner = split >= 0 ? name[..split] : null;
        var tool = split >= 0 ? name[(split + 2)..] : name;
        return owner switch
        {
            null or "developer" => tool switch
            {
                "shell" => ToolCategory.Command,
                "write" or "edit" or "tree" or "text_editor" or "read_image" => ToolCategory.File,
                "delegate" => ToolCategory.Agent,
                _ => ToolCategory.Other,
            },
            "summon" or "subagent" or "dynamic_task" => ToolCategory.Agent,
            _ => ToolCategory.Mcp,
        };
    }

    /// Names Goose gives a session before (or instead of) generating one: the ACP "New Chat", `--no-session`'s "CLI Session", a
    /// subagent's "Delegated task", and internal probes.
    static readonly HashSet<string> Placeholders = new(StringComparer.Ordinal) { "New Chat", "CLI Session", "Delegated task", "MCP Probe", "Tool Permission Configuration" };

    /// Providers that run another agent's CLI or ACP server (codex, cursor-agent, and every provider that manages its own
    /// context — claude-code, gemini-cli, the `*-acp` agents). That agent writes its own log, and Goose names the session from
    /// the first prompt's first words (`uses_local_session_naming`).
    static bool IsAgentProvider(string provider) =>
        provider is "codex" or "cursor-agent" or "claude-code" or "gemini-cli" || provider.EndsWith("-acp", StringComparison.Ordinal);

    /// The session's `name` (`description` before schema 3) when the person or client set it (`user_set_name`), a recipe titled
    /// it, or the model generated it; never a placeholder or a name cut from the first prompt.
    public static string? Title(string? raw, bool userSet, string? provider, bool recipe)
    {
        if (SessionTitle.Clean(raw) is not { } name) return null;
        if (userSet) return name;
        if (Placeholders.Contains(name)) return null;
        if (!recipe && provider is not null && IsAgentProvider(provider)) return null;
        return name;
    }

    internal static string? Short(string? value) => value is { Length: > 0 and <= 256 } ? value : null;

    static int Count(long? value) => value is > 0 ? (int)Math.Min(value.Value, int.MaxValue) : 0;

    internal static DateTimeOffset? Seconds(long? value) =>
        value is > 0 and < 253_402_300_800 ? DateTimeOffset.FromUnixTimeSeconds(value.Value) : null;
}

sealed record GooseListed(string Id, string? Directory, string? Title, DateTimeOffset Updated, string? Model, int? ContextLimit, string? ParentID,
    bool AgentProvider);

enum GooseRole { User, Assistant, Other }

/// One content block's type, ids and tool names; never its text, arguments or result.
sealed record GooseBlock(string? Type, string? Id, string? Tool, string? Action, string? ActionID, string? ActionTool, string? Notification);

enum GooseKind { User, Tools, Reply, Failure, Other }

/// One message's metadata; never its text.
sealed record GooseMessage(long Id, DateTimeOffset Created)
{
    public GooseRole Role { get; init; } = GooseRole.Other;
    /// The row's insert time (`timestamp`).
    public DateTimeOffset? Written { get; init; }
    public bool Visible { get; init; } = true;
    public int Output { get; init; }
    public double? ElapsedMs { get; init; }
    public double? TtftMs { get; init; }
    public string? Model { get; init; }
    public IReadOnlyList<GooseBlock> Blocks { get; init; } = [];

    public DateTimeOffset At => Written ?? Created;

    bool Has(params string[] types) => Blocks.Any(block => block.Type is { } type && types.Contains(type));
    public bool IsToolResponse => Has("toolResponse");
    /// A prompt from the person, where Goose's `active_turn_messages` starts the turn.
    public bool OpensTurn => Role == GooseRole.User && Visible && !IsToolResponse;

    /// What an assistant message means for the turn; `Other` (notices, an action block alone) leaves it as it was.
    public GooseKind Kind =>
        Role == GooseRole.User ? GooseKind.User
        : Has("toolRequest", "frontendToolRequest") ? GooseKind.Tools
        : Has("error") || Blocks.Any(block => block is { Type: "systemNotification", Notification: "creditsExhausted" }) ? GooseKind.Failure
        : Has("text", "thinking", "redactedThinking", "image", "document") ? GooseKind.Reply
        : GooseKind.Other;
}

sealed record GooseUsage(DateTimeOffset At, int Output, int Input, string? Model, bool Compaction);

sealed class GooseSession(string id)
{
    public string Id { get; } = id;
    public string? Directory { get; set; }
    public string? Title { get; set; }
    public string? SessionModel { get; set; }
    public int? ContextLimit { get; set; }
    public string? ParentID { get; set; }
    /// The session runs a CLI or ACP agent provider, whose own log TokenCat already reads: no output or speed from here.
    public bool AgentProvider { get; set; }
    public DateTimeOffset Updated { get; set; } = DateTimeOffset.MinValue;
    /// Newest first, at most 200.
    public List<GooseMessage> Messages { get; set; } = [];
    /// Content blocks by message row, parsed once.
    public Dictionary<long, List<GooseBlock>> Blocks { get; } = new();
    /// Ledger rows, newest first, at most 200.
    public List<GooseUsage> Usage { get; set; } = [];
    public GooseSummary Summary { get; set; } = new();
}

/// What a session's messages and ledger say, apart from the clock.
sealed record GooseSummary
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
    public TokenContextUsage? Context { get; init; }
    public TokenSpeedMeasurement? Speed { get; init; }

    public static GooseSummary Of(GooseSession session)
    {
        var ordered = Enumerable.Reverse(session.Messages).ToList();
        var usage = session.Usage;
        if (ordered.Count == 0 && usage.Count == 0) return new();
        var model = session.Messages.FirstOrDefault(message => message is { Role: GooseRole.Assistant, Model: not null })?.Model
            ?? usage.Select(row => row.Model).FirstOrDefault(name => name is not null);
        TokenContextUsage? context = null;
        if (usage.FirstOrDefault(row => row is { Compaction: false, Input: > 0 }) is { } latest)
        {
            var compacted = usage.FirstOrDefault(row => row.Compaction)?.At;
            context = new TokenContextUsage(latest.Input, null, latest.At, compacted >= latest.At ? compacted : null);
        }
        TokenSpeedMeasurement? speed = null;
        if (session.Messages.FirstOrDefault(message => message is { Role: GooseRole.Assistant, Output: > 0 }) is { ElapsedMs: { } duration } measured)
            speed = new TokenSpeedMeasurement(new TelemetryReading
            {
                Provider = TokenSource.Goose,
                At = measured.At,
                Model = measured.Model ?? model,
                OutputTokens = measured.Output,
                RequestDurationMs = duration,
                TtftMs = measured.TtftMs,
            });

        // Ledger output from `start` up to (not including) `end`.
        int Output(DateTimeOffset start, DateTimeOffset? end) =>
            usage.Where(row => row.At >= start && (end is not { } stop || row.At < stop)).Aggregate(0, (sum, row) => LogFields.Add(sum, row.Output));
        var openers = Enumerable.Range(0, ordered.Count).Where(index => ordered[index].OpensTurn).ToList();
        int? turnStart = openers.Count > 0 ? openers[^1] : null;
        var active = ordered.Skip(turnStart is { } first ? first + 1 : 0).ToList();

        var requests = new List<(string Id, string? Tool)>();
        var confirmations = new List<(string Id, string? Tool)>();
        var answered = new HashSet<string>(StringComparer.Ordinal);
        var confirmed = new HashSet<string>(StringComparer.Ordinal);
        var elicitations = new List<string>();
        var elicited = new HashSet<string>(StringComparer.Ordinal);
        foreach (var block in active.SelectMany(message => message.Blocks))
        {
            switch (block.Type)
            {
                case "toolRequest" or "frontendToolRequest" when block.Id is { } id: requests.Add((id, block.Tool)); break;
                case "toolResponse" when block.Id is { } id: answered.Add(id); break;
                case "toolConfirmationRequest" when block.Id is { } id: confirmations.Add((id, block.Tool)); break;
                case "actionRequired" when block.ActionID is { } id:
                    switch (block.Action)
                    {
                        case "toolConfirmation": confirmations.Add((id, block.ActionTool)); break;
                        case "toolConfirmationResponse": confirmed.Add(id); break;
                        case "elicitation": elicitations.Add(id); break;
                        case "elicitationResponse": elicited.Add(id); break;
                    }
                    break;
            }
        }
        var asking = confirmations.Where(request => !answered.Contains(request.Id) && !confirmed.Contains(request.Id)).ToList();
        var running = requests.Where(request => !answered.Contains(request.Id)).ToList();
        var lastKind = active.LastOrDefault(message => message.Kind != GooseKind.Other)?.Kind;
        var open = false;
        var state = TokenActivityState.Idle;
        string? toolName = null;
        var waits = false;
        if (asking.Count > 0 || elicitations.Any(id => !elicited.Contains(id)))
            (open, state, waits, toolName) = (true, TokenActivityState.Input, true, asking.Count > 0 ? asking[^1].Tool : running.Count > 0 ? running[^1].Tool : null);
        else if (running.Count > 0) (open, state, toolName) = (true, TokenActivityState.Tool, running[^1].Tool);
        else
            (open, state) = lastKind switch
            {
                GooseKind.Reply => (false, TokenActivityState.Complete),
                GooseKind.Failure => (false, TokenActivityState.Interrupted),
                GooseKind.Tools or GooseKind.User => (true, TokenActivityState.Working),
                // Nothing after the prompt yet: the model is answering it.
                _ => turnStart is not null ? (true, TokenActivityState.Working) : (false, TokenActivityState.Idle),
            };
        DateTimeOffset? startedAt = null;
        int? turnOutput = null;
        if (open && turnStart is { } start) (startedAt, turnOutput) = (ordered[start].Created, Output(ordered[start].Created, null));
        // The newest turn that ended in a reply, fully seen.
        (int, DateTimeOffset)? completion = null;
        for (var position = openers.Count - 1; position >= 0; position--)
        {
            var index = openers[position];
            var end = position + 1 < openers.Count ? openers[position + 1] : ordered.Count;
            var last = ordered.Skip(index + 1).Take(end - index - 1).LastOrDefault(message => message.Kind != GooseKind.Other);
            if (last is not { Kind: GooseKind.Reply }) continue;
            var total = Output(ordered[index].Created, end < ordered.Count ? ordered[end].Created : null);
            if (total > 0) completion = (total, last.At);
            break;
        }
        return new()
        {
            Open = open,
            State = state,
            ToolName = toolName,
            WaitsForInput = waits,
            StartedAt = startedAt,
            TurnOutput = turnOutput,
            Completion = completion,
            Outputs = [.. Enumerable.Reverse(usage).Where(row => row.Output > 0).Select(row => new TokenOutputEvent(row.At, row.Output))],
            LastActivity = ordered.Select(message => message.Created).Concat(usage.Select(row => row.At)).Max(),
            LastLogAt = ordered.Select(message => message.At).Concat(usage.Select(row => row.At)).Max(),
            Model = model,
            Context = context,
            Speed = speed,
        };
    }
}
