using System.Globalization;
using System.Text;

namespace TokenCat;

// Hermes Agent's SQLite store; mirrors the mac's Providers/HermesLog.swift. Only ids, roles, finish reasons, tool call ids
// and names, times, counters, model, cwd and the generated or renamed title are read; message content, reasoning, tool
// arguments and the system prompt are never selected.

public sealed partial record TokenLogFormat
{
    /// `<home>\state.db` and each profile's `<home>\profiles\<name>\state.db`. One reader covers every session in a store.
    public static readonly TokenLogFormat Hermes = new(
        (roots, discovery) => discovery.Recent(roots.SelectMany(root =>
                new[] { Path.Combine(root, "state.db") }.Concat(TokenDiscovery.Children(Path.Combine(root, "profiles"))
                    .OfType<DirectoryInfo>().Select(profile => Path.Combine(profile.FullName, "state.db"))))
            .Select(path => new FileInfo(path)).Where(file => file.Exists)),
        HermesLog.IsDatabase, path => new HermesLog(path));
}

/// Reads Hermes Agent (Nous Research) sessions from `state.db`, opened read-only (Hermes writes it in WAL mode), plus the
/// home's `logs\agent.log` for what the database does not keep.
/// - Re-queried when the database, its WAL or the WAL index header changed, and at least every 2 s while a session is in a
///   turn or active within the hour (NTFS may report a file held open with stale times, rule 8): the 64 most recently
///   active, unarchived sessions. A title Hermes derived from the first prompt (`derived`) is no title. Hidden sessions
///   are real work and are listed.
/// - Compression: a session ended with `end_reason = 'compression'` continues in a child; such a chain is one row named
///   after its first session, its newest segment giving the state. A subagent (`source = 'subagent'` or a
///   `_delegate_from` marker) is its own row under its parent's chain; a branch or a reset child is a top-level row.
/// - Turn: a person's message (not observed group chatter, not hidden compaction scaffolding) opens it; an assistant
///   message with tool calls runs them until their results are written; `stop` completes it; another finish interrupts
///   it. A tool shows only while later calls of a batch are outstanding (`clarify` waits for the person). agent.log's
///   `Turn ended` / `API call failed after` lines end a turn the database left open; a live turn lease keeps it active.
/// - Tokens: growth of `sessions.output_tokens` between reads, logged at the newest of the last message,
///   `last_activity_at` and the last `API call` log line; the first total read is a baseline unless the session started
///   after this reader's first read. Model: the main task's newest `session_model_usage` row, else `sessions.model`.
/// - Context and speed: agent.log's `API call #N: … in=<prompt> out=<n> … latency=<s>s` line for the session (`provider=moa`
///   is not a measurement); retries flagged when a retry or failure line for the session came before it.
public sealed class HermesLog(string path) : ITokenLogReader
{
    public string Path { get; } = path;
    readonly LogLineTail agentLog = new(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path) ?? "", "logs", "agent.log"));
    long[]? signature;
    DateTimeOffset? lastRead;
    DateTimeOffset? firstReadAt;
    Dictionary<string, HermesChain> chains = new(StringComparer.Ordinal);
    /// Ancestors looked up by id while finding a chain's first session; only ids still reached are kept.
    Dictionary<string, HermesSegment> lineage = new(StringComparer.Ordinal);
    /// Live turn leases: conversation (chain) id → expiry.
    Dictionary<string, DateTimeOffset> leases = new(StringComparer.Ordinal);
    readonly Dictionary<string, HermesLogSession> logSessions = new(StringComparer.Ordinal);

    static readonly string? OverrideHome = TokenProvider.EnvPath(AppPaths.Home, Environment.GetEnvironmentVariable, "HERMES_HOME");

    /// `state.db` in a Hermes home (`.hermes`, Windows `hermes`, or `HERMES_HOME`) or in a profile under `profiles`.
    public static bool IsDatabase(string path)
    {
        if (!string.Equals(System.IO.Path.GetFileName(path), "state.db", StringComparison.OrdinalIgnoreCase)) return false;
        var folder = System.IO.Path.GetDirectoryName(path) ?? "";
        var name = System.IO.Path.GetFileName(folder);
        return string.Equals(name, ".hermes", StringComparison.OrdinalIgnoreCase) || string.Equals(name, "hermes", StringComparison.OrdinalIgnoreCase)
            || string.Equals(System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(folder) ?? ""), "profiles", StringComparison.OrdinalIgnoreCase)
            || (OverrideHome is not null && string.Equals(folder, OverrideHome, StringComparison.OrdinalIgnoreCase));
    }

    /// The root Hermes lists profiles under: a `HERMES_HOME` of `<root>\profiles\<name>` names `<root>`.
    public static string Root(string home)
    {
        // Cut the given string itself: GetDirectoryName rewrites '/' to '\' on Windows, so the root would not match the roots
        // other paths are compared with.
        var trimmed = home.TrimEnd('/', '\\');
        var name = trimmed.LastIndexOfAny(['/', '\\']);
        if (name <= 0) return trimmed;
        var parent = trimmed[..name];
        var profiles = parent.LastIndexOfAny(['/', '\\']);
        return profiles > 0 && string.Equals(parent[(profiles + 1)..], "profiles", StringComparison.OrdinalIgnoreCase) ? parent[..profiles] : trimmed;
    }

    // Reading

    public void Read(int tailLimit, DateTimeOffset now)
    {
        firstReadAt ??= now;
        var ceiling = now.AddSeconds(5);
        foreach (var chain in chains.Values) chain.Turn.Clamp(ceiling);
        agentLog.Read(tailLimit, () => { }, Consume);
        if (OpenCodeDatabase.Signature(Path) is { } current)
        {
            var hot = chains.Values.Any(chain => chain.Turn.IsRecent(now));
            if (signature is null || !current.SequenceEqual(signature) || (hot && lastRead is { } last && (now - last).TotalSeconds >= 2))
            {
                signature = ReadDatabase(now) ? current : null;
                lastRead = now;
            }
        }
        foreach (var chain in chains.Values) ApplyLog(chain, now);
    }

    /// False when the database refused a read; the next read queries it again.
    bool ReadDatabase(DateTimeOffset now)
    {
        using var database = Open(Path);
        if (database is null || !database.Execute("BEGIN")) return false;
        try
        {
            var listed = new List<HermesSegment>();
            void Collect(OpenCodeDatabase.Row row)
            {
                if (row.Text(0) is not { } id) return;
                listed.Add(new HermesSegment(id)
                {
                    Source = row.Text(1),
                    Parent = row.Text(2),
                    Model = Name(row.Text(3)),
                    Cwd = row.Text(4),
                    Title = SessionTitle.Clean(row.Text(5)),
                    StartedAt = Date(row.Double(6)),
                    EndedAt = Date(row.Double(7)),
                    EndReason = row.Text(8),
                    LastActivityAt = Date(row.Double(9)),
                    Output = Count(row.Int64(10)),
                    MessageCount = Count(row.Int64(11)),
                    Delegated = row.Int64(12) == 1,
                    Branched = row.Int64(13) == 1,
                });
            }
            // Pre-provenance rows (NULL title_source) were titled by the model or the person; `derived` copies the prompt.
            const string current = """
                SELECT id, source, parent_session_id, model, cwd,
                       CASE WHEN title_source IS NULL OR title_source IN ('llm', 'user') THEN substr(title, 1, 256) END,
                       started_at, ended_at, end_reason, last_activity_at, output_tokens, message_count,
                       CASE WHEN json_valid(model_config) THEN json_extract(model_config, '$._delegate_from') IS NOT NULL ELSE 0 END,
                       CASE WHEN json_valid(model_config) THEN json_extract(model_config, '$._branched_from') IS NOT NULL ELSE 0 END
                FROM sessions WHERE archived = 0
                ORDER BY MAX(started_at, COALESCE(last_activity_at, 0), COALESCE(ended_at, 0)) DESC LIMIT 64
                """;
            // Older schemas lack the title provenance, activity stamp and archive flag (or SQLite lacks JSON functions).
            const string older = """
                SELECT id, source, parent_session_id, model, cwd, NULL, started_at, ended_at, end_reason, NULL, output_tokens,
                       message_count, 0, 0
                FROM sessions ORDER BY MAX(started_at, COALESCE(ended_at, 0)) DESC LIMIT 64
                """;
            if (!database.Query(current, [], Collect) && !(listed.Count == 0 && database.Query(older, [], Collect))) return false;

            var known = new Dictionary<string, HermesSegment>(StringComparer.Ordinal);
            foreach (var segment in listed) known.TryAdd(segment.Id, segment);
            var reached = new HashSet<string>(StringComparer.Ordinal);
            HermesSegment? Lookup(string id)
            {
                if (known.TryGetValue(id, out var segment)) return segment;
                reached.Add(id);
                if (lineage.TryGetValue(id, out var cached)) return cached;
                HermesSegment? found = null;
                database.Query("""
                    SELECT source, parent_session_id, end_reason, started_at,
                           CASE WHEN json_valid(model_config) THEN json_extract(model_config, '$._delegate_from') IS NOT NULL ELSE 0 END,
                           CASE WHEN json_valid(model_config) THEN json_extract(model_config, '$._branched_from') IS NOT NULL ELSE 0 END
                    FROM sessions WHERE id = ?
                    """, [id], row => found = new HermesSegment(id)
                {
                    Source = row.Text(0),
                    Parent = row.Text(1),
                    EndReason = row.Text(2),
                    StartedAt = Date(row.Double(3)),
                    Delegated = row.Int64(4) == 1,
                    Branched = row.Int64(5) == 1,
                });
                if (found is not null)
                {
                    lineage[id] = found;
                    known[id] = found;
                }
                return found;
            }
            // The first session of the compression chain `id` belongs to.
            string RootOf(string id)
            {
                var current = id;
                var seen = new HashSet<string>(StringComparer.Ordinal) { id };
                for (var step = 0; step < 100; step++)
                {
                    if (Lookup(current) is not { ContinuesParent: true, Parent: { } parent } || seen.Contains(parent)
                        || Lookup(parent) is not { EndReason: "compression" }) break;
                    seen.Add(parent);
                    current = parent;
                }
                return current;
            }

            var order = new List<string>();
            var grouped = new Dictionary<string, List<HermesSegment>>(StringComparer.Ordinal);
            foreach (var segment in listed)
            {
                var chainID = RootOf(segment.Id);
                if (!grouped.TryGetValue(chainID, out var members)) grouped[chainID] = members = [];
                if (members.Count == 0) order.Add(chainID);
                members.Add(segment);
            }
            var kept = new Dictionary<string, HermesChain>(StringComparer.Ordinal);
            var complete = true;
            for (var offset = 0; offset < order.Count; offset++)
            {
                var chainID = order[offset];
                var segments = grouped[chainID];
                var tip = segments.FirstOrDefault(segment => segment.EndReason != "compression") ?? segments[0];
                chains.TryGetValue(chainID, out var existing);
                if (offset >= 32 && (now - tip.Activity).TotalSeconds > 3_600 && existing?.Turn.TurnOpen != true) continue;
                var first = Lookup(chainID) ?? tip;
                var chain = existing ?? new HermesChain(chainID, (first.StartedAt ?? tip.StartedAt) is { } started && started > (firstReadAt ?? now));
                chain.Spawned = first.Spawned;
                chain.Parent = first.Spawned && first.Parent is { } parent ? RootOf(parent) : null;
                chain.Segments = [.. segments.Select(segment => segment.Id)];
                chain.Title = tip.Title ?? segments.Select(segment => segment.Title).FirstOrDefault(title => title is not null) ?? first.Title;
                chain.Cwd = tip.Cwd ?? segments.Select(segment => segment.Cwd).FirstOrDefault(cwd => cwd is not null) ?? first.Cwd;
                chain.SessionModel = tip.Model ?? segments.Select(segment => segment.Model).FirstOrDefault(model => model is not null);
                if (!Refresh(chain, tip, segments, database, now)) complete = false;
                kept[chainID] = chain;
            }
            chains = kept;
            lineage = lineage.Where(entry => reached.Contains(entry.Key)).ToDictionary(StringComparer.Ordinal);

            var live = new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
            database.Query("SELECT conversation_id, expires_at FROM session_turn_leases", [], row =>
            {
                if (row.Text(0) is { } id && Date(row.Double(1)) is { } expires) live[id] = expires;
            });
            leases = live;
            return complete;
        }
        finally { database.Execute("COMMIT"); }
    }

    /// New messages of the chain's newest segment as turn events, then token growth. False when the database refused a
    /// read; the chain keeps its state and is read again.
    bool Refresh(HermesChain chain, HermesSegment tip, List<HermesSegment> segments, OpenCodeDatabase database, DateTimeOffset now)
    {
        if (!tip.Stamp.SequenceEqual(chain.Stamp) || tip.Id != chain.Tip)
        {
            string? model = null;
            database.Query("SELECT model FROM session_model_usage WHERE session_id = ? AND task = '' ORDER BY last_seen DESC LIMIT 1",
                [tip.Id], row => model = Name(row.Text(0)));
            chain.UsageModel = model;
            if (!Events(chain, tip, segments, database)) return false;
            chain.Tip = tip.Id;
            chain.Stamp = tip.Stamp;
        }
        chain.Turn.Logged(tip.LastActivityAt);
        var growth = 0;
        foreach (var segment in segments)
        {
            var previous = chain.Totals.TryGetValue(segment.Id, out var total) ? total : chain.Baselined || chain.Fresh ? 0 : segment.Output;
            if (segment.Output > previous) growth = LogFields.Add(growth, segment.Output - previous);
            chain.Totals[segment.Id] = segment.Output;
        }
        chain.Baselined = true;
        if (growth <= 0) return true;
        var info = LogInfo(chain);
        var newest = new[] { chain.LastMessageAt, tip.LastActivityAt, info.Call?.At, chain.CreditAt }.OfType<DateTimeOffset>().DefaultIfEmpty(now).Max();
        var ceiling = now.AddSeconds(5);
        var at = newest < ceiling ? newest : ceiling;
        chain.CreditAt = at;
        chain.Turn.Logged(at);
        chain.Turn.AddOutput(growth, at);
        return true;
    }

    bool Events(HermesChain chain, HermesSegment tip, List<HermesSegment> segments, OpenCodeDatabase database)
    {
        var cold = chain.ProcessedID == 0 && !chain.Fresh;
        var rows = new List<HermesMessageRow>();
        void Collect(OpenCodeDatabase.Row row)
        {
            if (row.Int64(0) is not { } id || row.Text(1) is not { } role || Date(row.Double(4)) is not { } at) return;
            rows.Add(new HermesMessageRow(id, role, row.Text(2), row.Text(3), at, row.Int64(5) == 1, row.Int64(6) == 1));
        }
        var limit = cold ? 64 : 512;
        var filter = $"session_id = ? AND id > {chain.ProcessedID.ToString(CultureInfo.InvariantCulture)}";
        // Older schemas lack `active`, `observed` and `display_kind`.
        var modern = true;
        if (!database.Query($"""
                SELECT id, role, finish_reason, tool_call_id, timestamp, observed, COALESCE(display_kind, '') = 'hidden'
                FROM messages WHERE {filter} AND active = 1 ORDER BY id DESC LIMIT {limit}
                """, [tip.Id], Collect))
        {
            modern = false;
            rows.Clear();
            if (!database.Query($"SELECT id, role, finish_reason, tool_call_id, timestamp, 0, 0 FROM messages WHERE {filter} ORDER BY id DESC LIMIT {limit}",
                    [tip.Id], Collect)) return false;
        }
        rows.Reverse();
        var calls = new Dictionary<long, List<(string Id, string? Name)>>();
        if (rows.Count > 0)
        {
            // Ids and names only (never arguments); SQLite without JSON functions leaves the calls unnamed and unmatched.
            database.Query($"""
                SELECT m.id, json_extract(j.value, '$.id'), substr(json_extract(j.value, '$.function.name'), 1, 128)
                FROM messages m, json_each(CASE WHEN json_valid(m.tool_calls) THEN m.tool_calls END) j
                WHERE m.session_id = ? AND m.id >= {rows[0].Id.ToString(CultureInfo.InvariantCulture)} AND m.role = 'assistant' AND m.tool_calls IS NOT NULL
                """, [tip.Id], row =>
            {
                if (row.Int64(0) is not { } message || row.Text(1) is not { } id) return;
                if (!calls.TryGetValue(message, out var batch)) calls[message] = batch = [];
                batch.Add((id, row.Text(2)));
            });
        }
        // A cold read that starts inside a turn: its prompt may lie further back, or in an earlier compression segment.
        if (cold && rows.Count > 0 && !(rows[0] is { Role: "user", Observed: false, Scaffold: false }))
        {
            var ids = segments.Select(segment => segment.Id).Append(tip.Id).Distinct(StringComparer.Ordinal).ToArray();
            var marks = string.Join(", ", ids.Select(_ => "?"));
            var prompt = modern ? " AND observed = 0 AND COALESCE(display_kind, '') != 'hidden'" : "";
            DateTimeOffset? promptAt = null;
            database.Query($"""
                SELECT timestamp FROM messages WHERE session_id IN ({marks}) AND id < {rows[0].Id.ToString(CultureInfo.InvariantCulture)} AND role = 'user'{prompt}
                ORDER BY id DESC LIMIT 1
                """, [.. ids], row => promptAt = Date(row.Double(0)));
            if (promptAt is { } start)
            {
                chain.Turn.Begin(start, whole: false);
                chain.PromptAt = start;
            }
        }
        foreach (var row in rows)
        {
            chain.ProcessedID = Math.Max(chain.ProcessedID, row.Id);
            chain.LastMessageAt = chain.LastMessageAt is { } previous && previous > row.At ? previous : row.At;
            chain.Turn.Logged(row.At);
            if (row.Scaffold) continue;
            // A message from a turn the log already closed must not reopen it.
            var late = !chain.Turn.TurnOpen && chain.ClosedAt is { } closed && row.At <= closed;
            switch (row.Role)
            {
                case "user":
                    if (row.Observed) continue;
                    chain.Turn.Begin(row.At, whole: chain.Baselined || chain.Fresh);
                    chain.PromptAt = row.At;
                    chain.ClosedAt = null;
                    break;
                case "tool":
                    if (late) continue;
                    chain.Turn.Resume(row.At);
                    if (row.ToolCallID is { } id) chain.Turn.FinishTool(id, row.At);
                    break;
                case "assistant":
                    if (late) continue;
                    chain.Turn.Resume(row.At);
                    // Last to first: the shared bookkeeping shows the newest outstanding call, and Hermes runs a batch in order.
                    if (calls.TryGetValue(row.Id, out var batch) && batch.Count > 0)
                    {
                        for (var index = batch.Count - 1; index >= 0; index--) chain.Turn.StartTool(batch[index].Id, batch[index].Name, row.At);
                    }
                    else if (row.Finish == "stop")
                    {
                        chain.Turn.Close(TokenActivityState.Complete, row.At, chain.Model);
                        chain.ClosedAt = row.At;
                    }
                    else if (row.Finish is { } finish && finish != "tool_calls")
                    {
                        chain.Turn.Close(TokenActivityState.Interrupted, row.At, chain.Model);
                        chain.ClosedAt = row.At;
                    }
                    else chain.Turn.SetState(TokenActivityState.Working, row.At);
                    break;
            }
        }
        return true;
    }

    /// Log liveness, a turn end the database did not record, the context in use and the latest measured request.
    void ApplyLog(HermesChain chain, DateTimeOffset now)
    {
        var info = LogInfo(chain);
        var ceiling = now.AddSeconds(5);
        DateTimeOffset Cap(DateTimeOffset at) => at < ceiling ? at : ceiling;
        if (info.LastLineAt is { } line) chain.Turn.Logged(Cap(line));
        var leased = leases.TryGetValue(chain.Root, out var expires) && expires > now;
        if (leased) chain.Turn.Logged(now);
        // The end belongs to the open turn when it follows that turn's start line (Hermes stores the prompt within
        // moments of logging it) and every message stored so far; a prompt that interrupted the previous turn comes
        // before that turn's end line but after its start.
        if (chain.Turn.TurnOpen && !leased && info.End is { } end && end.At >= (info.Start ?? DateTimeOffset.MinValue)
            && end.At >= (chain.LastMessageAt ?? DateTimeOffset.MinValue)
            && (chain.PromptAt is not { } prompt || prompt <= (info.Start ?? end.At).AddSeconds(2)))
        {
            chain.Turn.Close(end.State, Cap(end.At), chain.Model);
            chain.ClosedAt = end.At;
        }
        if (info.Call is { } call)
        {
            chain.Context = call.Input > 0 ? new TokenContextUsage(call.Input, null, Cap(call.At), null) : null;
            chain.Speed = call.Provider != "moa" && call.Output > 0 && call.Latency > 0
                ? new TokenSpeedMeasurement(new TelemetryReading
                {
                    Provider = TokenSource.Hermes,
                    At = Cap(call.At),
                    SessionID = chain.Root,
                    Model = call.Model ?? chain.Model,
                    OutputTokens = call.Output,
                    RequestDurationMs = Math.Round(call.Latency * 1_000),
                    RequestDurationIncludesRetries = call.Retried,
                })
                : null;
        }
    }

    /// What agent.log says about any segment of the chain.
    HermesLogSession LogInfo(HermesChain chain)
    {
        var merged = new HermesLogSession();
        foreach (var id in chain.Segments.Append(chain.Root).Distinct(StringComparer.Ordinal))
        {
            if (!logSessions.TryGetValue(id, out var entry)) continue;
            if (entry.LastLineAt > (merged.LastLineAt ?? DateTimeOffset.MinValue)) merged.LastLineAt = entry.LastLineAt;
            if (entry.Start > (merged.Start ?? DateTimeOffset.MinValue)) merged.Start = entry.Start;
            if (entry.End is { } end && end.At > (merged.End?.At ?? DateTimeOffset.MinValue)) merged.End = end;
            if (entry.Call is { } call && call.At > (merged.Call?.At ?? DateTimeOffset.MinValue)) merged.Call = call;
        }
        return merged;
    }

    // agent.log

    /// `YYYY-MM-DD HH:MM:SS,mmm LEVEL [<session id>] <logger>: <message>`. Only the first 512 bytes are decoded; only times,
    /// counts, model and provider names are kept.
    void Consume(byte[] line)
    {
        if (line.Length <= 30 || line[23] != 32) return;
        // Python's text-mode log handler ends lines in CRLF on Windows.
        var head = Encoding.UTF8.GetString(line, 0, Math.Min(line.Length, 512)).Trim('\r');
        // Python logging's local `asctime`; kept as UTC like every other time (rule 4).
        if (!DateTimeOffset.TryParseExact(head[..23], "yyyy-MM-dd HH:mm:ss,fff", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var local)) return;
        var date = local.ToUniversalTime();
        var afterTime = head[24..];
        var levelLength = 0;
        while (levelLength < afterTime.Length && afterTime[levelLength] is >= 'A' and <= 'Z') levelLength++;
        var level = afterTime[..levelLength];
        var tagged = afterTime[levelLength..];
        var close = tagged.IndexOf(']');
        if (levelLength == 0 || !tagged.StartsWith(" [", StringComparison.Ordinal) || close < 2) return;
        var session = tagged[2..close];
        if (session.Length is < 1 or > 64 || !session.All(c => char.IsLetterOrDigit(c) || c is '_' or '-' or '.')) return;
        var rest = close + 2 <= tagged.Length ? tagged[(close + 2)..] : "";
        if (!logSessions.TryGetValue(session, out var entry)) logSessions[session] = entry = new HermesLogSession();
        if (date > (entry.LastLineAt ?? DateTimeOffset.MinValue)) entry.LastLineAt = date;
        var warning = level is "WARNING" or "ERROR";
        const string loop = "agent.conversation_loop: ";
        if (rest.StartsWith(loop, StringComparison.Ordinal))
        {
            var message = rest[loop.Length..];
            if (message.StartsWith("API call #", StringComparison.Ordinal))
            {
                var call = new HermesCall(date, entry.Retrying);
                foreach (var field in message.Split(' '))
                {
                    var equals = field.IndexOf('=');
                    if (equals < 0) continue;
                    var value = field[(equals + 1)..];
                    switch (field[..equals])
                    {
                        case "model": call.Model = Name(value); break;
                        case "provider": call.Provider = value.Length > 64 ? value[..64] : value; break;
                        case "in": call.Input = int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var input) ? Math.Max(0, input) : 0; break;
                        case "out": call.Output = int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var output) ? Math.Max(0, output) : 0; break;
                        case "latency":
                            call.Latency = double.TryParse(value.EndsWith('s') ? value[..^1] : value, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)
                                && double.IsFinite(seconds) ? seconds : 0;
                            break;
                    }
                }
                entry.Call = call;
                entry.Retrying = false;
            }
            else if (message.StartsWith("Turn ended: reason=", StringComparison.Ordinal))
                entry.End = (date, message[19..].StartsWith("text_response", StringComparison.Ordinal) ? TokenActivityState.Complete : TokenActivityState.Interrupted);
            else if (message.StartsWith("API call failed after", StringComparison.Ordinal))
            {
                entry.End = (date, TokenActivityState.Interrupted);
                entry.Retrying = false;
            }
            else if (warning && (message.StartsWith("Retrying API call", StringComparison.Ordinal) || message.StartsWith("API call failed", StringComparison.Ordinal)
                                 || message.StartsWith("Invalid API response", StringComparison.Ordinal)))
                entry.Retrying = true;
        }
        else if (warning && rest.StartsWith("agent.chat_completion_helpers: ", StringComparison.Ordinal)) entry.Retrying = true;
        else if (rest.StartsWith("agent.turn_context: conversation turn:", StringComparison.Ordinal))
        {
            entry.Start = date;
            entry.Retrying = false;
        }
        if (logSessions.Count > 512)
            logSessions.Remove(logSessions.MinBy(pair => pair.Value.LastLineAt ?? DateTimeOffset.MinValue).Key);
    }

    // Readings

    public bool IsRecent(DateTimeOffset now) => chains.Values.Any(chain => chain.Turn.IsRecent(now));

    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        var readings = new List<TokenReading>();
        foreach (var chain in chains.Values)
        {
            var cwd = chain.Cwd ?? (chain.Parent is { } parent && chains.TryGetValue(parent, out var owner) ? owner.Cwd : null);
            if (chain.Turn.Reading(TokenSource.Hermes, $"{id}#{chain.Root}", chain.Model, cwd, now) is not { } reading) continue;
            readings.Add(reading with
            {
                SessionID = chain.Root,
                Title = chain.Title,
                IsSubagent = chain.Spawned,
                ParentSessionID = chain.Spawned ? chain.Parent : null,
                AgentID = chain.Spawned ? chain.Root : null,
                ToolCategory = reading.ToolName is { } tool ? Category(tool) : reading.ToolCategory,
                Context = chain.Context,
                SpeedMeasurement = chain.Speed,
            });
        }
        return readings;
    }

    /// Hermes's built-in tool names; MCP tools are `mcp__<server>__<tool>`.
    public static ToolCategory Category(string name) =>
        name.StartsWith("mcp__", StringComparison.Ordinal) ? ToolCategory.Mcp
        : name.StartsWith("browser_", StringComparison.Ordinal) ? ToolCategory.Web
        : name switch
        {
            "terminal" or "process" or "execute_code" or "read_terminal" or "close_terminal" => ToolCategory.Command,
            "read_file" or "write_file" or "patch" or "search_files" or "read_preview" => ToolCategory.File,
            "web_search" or "web_extract" or "x_search" => ToolCategory.Web,
            "delegate_task" => ToolCategory.Agent,
            "clarify" => ToolCategory.Question,
            _ => ToolCategory.Other,
        };

    // Values

    /// Opens the store read-only. A WAL database whose last writer closed has no `-wal`/`-shm`, and a read-only connection
    /// cannot create them, so SQLite refuses it; with no WAL file nothing is mid-write and nothing reaches the main file
    /// until a writer's checkpoint, so it is read as immutable then.
    static OpenCodeDatabase? Open(string path)
    {
        var database = OpenCodeDatabase.Open(path);
        if (database is not null && database.Query("SELECT 1 FROM sqlite_master LIMIT 1", [], _ => { })) return database;
        database?.Dispose();
        return !File.Exists(path + "-wal") && IsWALDatabase(path) ? OpenCodeDatabase.Open(path, immutable: true) : null;
    }

    /// The header's file format bytes say WAL (2).
    static bool IsWALDatabase(string path)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, bufferSize: 0);
            var header = new byte[20];
            return file.ReadAtLeast(header, header.Length, throwOnEndOfStream: false) == header.Length && header[18] == 2 && header[19] == 2;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }

    internal static DateTimeOffset? Date(double? seconds) =>
        seconds is { } value && double.IsFinite(value) && value > 0 && value < 253_402_300_800
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(value * 1_000)) : null;

    static int Count(long? value) => value is { } number && number > 0 ? (int)Math.Min(number, int.MaxValue) : 0;

    static string? Name(string? text) => text is { Length: > 0 and <= 256 } ? text : null;
}

/// One `sessions` row: metadata and counters only.
sealed record HermesSegment(string Id)
{
    public string? Source { get; init; }
    public string? Parent { get; init; }
    public string? Model { get; init; }
    public string? Cwd { get; init; }
    public string? Title { get; init; }
    public DateTimeOffset? StartedAt { get; init; }
    public DateTimeOffset? EndedAt { get; init; }
    public string? EndReason { get; init; }
    public DateTimeOffset? LastActivityAt { get; init; }
    public int Output { get; init; }
    public int MessageCount { get; init; }
    public bool Delegated { get; init; }
    public bool Branched { get; init; }

    /// A delegated subagent (or a tool-spawned child); its own row under its parent.
    public bool Spawned => Source == "subagent" || Delegated || (Source == "tool" && Parent is not null);
    /// Continues its parent when that parent ended in compression (Hermes's own lineage rule, plus older subagents).
    public bool ContinuesParent => !Delegated && !Branched && Source != "tool" && Source != "subagent";
    public DateTimeOffset Activity => new[] { StartedAt, LastActivityAt, EndedAt }.OfType<DateTimeOffset>().DefaultIfEmpty(DateTimeOffset.MinValue).Max();
    /// Changes whenever a message is stored or the session's counters, end or activity move.
    public double[] Stamp => [MessageCount, Output, EndedAt?.ToUnixTimeMilliseconds() ?? 0, LastActivityAt?.ToUnixTimeMilliseconds() ?? 0];
}

/// `Scaffold`: compaction references and interruption placeholders (`display_kind = 'hidden'`). Other kinds (an internal
/// notification, a synthesized continuation) still open a turn.
readonly record struct HermesMessageRow(long Id, string Role, string? Finish, string? ToolCallID, DateTimeOffset At, bool Observed, bool Scaffold);

/// One compression chain (most are a single session), named after its first session. `Fresh`: started after this
/// reader's first read, so its totals start at zero and its first turn is whole.
sealed class HermesChain(string root, bool fresh)
{
    public string Root { get; } = root;
    public bool Fresh { get; } = fresh;
    public LogTurnState Turn { get; } = new(new HashSet<string> { "clarify" });
    public List<string> Segments { get; set; } = [];
    public string Tip { get; set; } = "";
    public double[] Stamp { get; set; } = [];
    /// Output total per segment at the latest read.
    public Dictionary<string, int> Totals { get; } = new(StringComparer.Ordinal);
    public bool Baselined { get; set; }
    public long ProcessedID { get; set; }
    public DateTimeOffset? PromptAt { get; set; }
    public DateTimeOffset? LastMessageAt { get; set; }
    public DateTimeOffset? ClosedAt { get; set; }
    public DateTimeOffset? CreditAt { get; set; }
    public string? UsageModel { get; set; }
    public string? SessionModel { get; set; }
    public string? Cwd { get; set; }
    public string? Title { get; set; }
    public bool Spawned { get; set; }
    public string? Parent { get; set; }
    public TokenContextUsage? Context { get; set; }
    public TokenSpeedMeasurement? Speed { get; set; }
    public string? Model => UsageModel ?? SessionModel;
}

sealed class HermesCall(DateTimeOffset at, bool retried)
{
    public DateTimeOffset At { get; } = at;
    public bool Retried { get; } = retried;
    public string? Model { get; set; }
    public string? Provider { get; set; }
    public int Input { get; set; }
    public int Output { get; set; }
    public double Latency { get; set; }
}

/// What agent.log said about one session id.
sealed class HermesLogSession
{
    public DateTimeOffset? LastLineAt { get; set; }
    /// The latest `conversation turn` (turn start) line.
    public DateTimeOffset? Start { get; set; }
    public (DateTimeOffset At, TokenActivityState State)? End { get; set; }
    public HermesCall? Call { get; set; }
    /// A retry or failure line since the latest `API call` line.
    public bool Retrying { get; set; }
}
