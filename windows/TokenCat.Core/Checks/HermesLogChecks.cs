using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TokenCat;

/// HermesLogChecks.swift: Hermes Agent fixture stores (synthetic metadata; every text column holds a PRIVATE marker) — an
/// open tool turn, a question waiting in a subagent, a compression chain as one row, a turn only agent.log ended, a
/// profile database whose writer closed (no `-wal`), token growth into a whole turn, and no text in any reading. Run from
/// `TrackerChecks.Run`; descriptions verbatim. The store lives in %LOCALAPPDATA%\hermes (here `<home>\AppData\Local\hermes`).
static class HermesLogChecks
{
    public static void Run(string root, Action<bool, string> check)
    {
        var now = DateTimeOffset.Parse("2026-10-04T06:00:00Z", CultureInfo.InvariantCulture);
        // REAL values go inline: the fixture connection binds text, integers and null only.
        string At(double seconds) => (now.ToUnixTimeMilliseconds() / 1_000.0 + seconds).ToString("R", CultureInfo.InvariantCulture);
        string LogLine(double seconds, string level, string session, string text) =>
            $"{now.AddSeconds(seconds).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss,fff", CultureInfo.InvariantCulture)} {level} [{session}] {text}\n";

        var home = Path.Combine(root, "hermes-home");
        var hermes = Path.Combine(home, "AppData", "Local", "hermes");
        var profile = Path.Combine(hermes, "profiles", "work");
        var logs = Path.Combine(hermes, "logs");
        Directory.CreateDirectory(logs);
        Directory.CreateDirectory(profile);
        var path = Path.Combine(hermes, "state.db");
        var profilePath = Path.Combine(profile, "state.db");
        var failed = false;
        void Sql(OpenCodeDatabase? database, string sql, params object?[] values) => failed |= database is null || !database.Query(sql, values, _ => { });
        // The subset of Hermes's schema (v26) the reader touches, with its text columns.
        void Schema(OpenCodeDatabase? database)
        {
            Sql(database, """
                CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, model_config TEXT, system_prompt TEXT,
                parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL, end_reason TEXT, message_count INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0, cwd TEXT, title TEXT, title_source TEXT, last_activity_at REAL,
                last_activity_description TEXT, archived INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0)
                """);
            Sql(database, """
                CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT,
                tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL NOT NULL, finish_reason TEXT, reasoning TEXT,
                observed INTEGER DEFAULT 0, active INTEGER NOT NULL DEFAULT 1, display_kind TEXT)
                """);
            Sql(database, "CREATE INDEX idx_messages_session_id ON messages(session_id, id)");
            Sql(database, "CREATE TABLE session_model_usage (session_id TEXT, model TEXT, task TEXT, output_tokens INTEGER, last_seen REAL)");
            Sql(database, "CREATE TABLE session_turn_leases (conversation_id TEXT PRIMARY KEY, holder TEXT NOT NULL, acquired_at REAL NOT NULL, expires_at REAL NOT NULL)");
        }
        void Session(OpenCodeDatabase? database, string id, double started, double activity, string? cwd, string source = "cli", string? parent = null,
            string? config = null, double? ended = null, string? reason = null, long output = 0, string? title = null, string titleSource = "llm",
            bool archived = false) =>
            Sql(database, $"INSERT INTO sessions VALUES (?, ?, 'session-model', ?, 'PRIVATE system prompt', ?, {At(started)}, {(ended is { } end ? At(end) : "NULL")}, ?, 0, ?, ?, ?, ?, {At(activity)}, 'PRIVATE activity', ?, 0)",
                id, source, config, parent, reason, output, cwd, title, title is null ? null : titleSource, archived ? 1L : 0L);
        void Message(OpenCodeDatabase? database, string session, string role, double seconds, string? finish = null,
            (string Id, string Name)[]? calls = null, string? result = null, string? kind = null)
        {
            var toolCalls = calls is { Length: > 0 }
                ? JsonSerializer.Serialize(calls.Select(call => new
                {
                    id = call.Id, call_id = call.Id, type = "function",
                    function = new { name = call.Name, arguments = "{\"command\":\"PRIVATE argument\"}" },
                }))
                : null;
            Sql(database, $"INSERT INTO messages (session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, finish_reason, reasoning, display_kind) VALUES (?, ?, 'PRIVATE content', ?, ?, ?, {At(seconds)}, ?, 'PRIVATE reasoning', ?)",
                session, role, result, toolCalls, result is null ? null : "terminal", finish, kind);
        }

        using var database = OpenCodeDatabase.Open(path, create: true);
        Schema(database);
        // An open turn: the first of two tool calls returned, read_file still runs.
        Session(database, "ses_tool", -60, -10, "/tmp/HermesWork", output: 1_000, title: "Fix login\nflow");
        Message(database, "ses_tool", "user", -30);
        Message(database, "ses_tool", "assistant", -10, "tool_calls", [("c1", "terminal"), ("c2", "read_file")]);
        Message(database, "ses_tool", "tool", -10, result: "c1");
        Sql(database, $"INSERT INTO session_model_usage VALUES ('ses_tool', 'title-model', 'title_generation', 9, {At(-5)})");
        Sql(database, $"INSERT INTO session_model_usage VALUES ('ses_tool', 'fixture-model', '', 900, {At(-10)})");
        // A finished turn whose title Hermes derived from the prompt (no title).
        Session(database, "ses_done", -200, -50, "/tmp/HermesDone", output: 500, title: "PRIVATE derived title", titleSource: "derived");
        Message(database, "ses_done", "user", -100);
        Message(database, "ses_done", "assistant", -50, "stop");
        // A delegated subagent whose second call asks the person.
        Session(database, "ses_child", -25, -20, null, source: "subagent", parent: "ses_tool", config: "{\"_delegate_from\":\"ses_tool\"}");
        Message(database, "ses_child", "user", -24);
        Message(database, "ses_child", "assistant", -20, "tool_calls", [("c3", "terminal"), ("c4", "clarify")]);
        Message(database, "ses_child", "tool", -20, result: "c3");
        // A compression chain: the prompt sits in the ended first segment, the turn continues in the second.
        Session(database, "ses_long", -400, -60, "/tmp/HermesLong", ended: -60, reason: "compression", output: 4_000, title: "Long refactor");
        Message(database, "ses_long", "user", -200);
        Message(database, "ses_long", "assistant", -150, "tool_calls", [("c5", "terminal")]);
        Message(database, "ses_long", "tool", -150, result: "c5");
        Session(database, "ses_long_2", -60, -40, "/tmp/HermesLong", parent: "ses_long", output: 300, title: "Long refactor");
        Message(database, "ses_long_2", "user", -60, kind: "hidden");
        Message(database, "ses_long_2", "assistant", -40, "tool_calls", [("c6", "patch")]);
        Message(database, "ses_long_2", "tool", -40, result: "c6");
        // A request that failed after its retries: no assistant message, only agent.log ends the turn.
        Session(database, "ses_fail", -90, -40, null, source: "desktop");
        Message(database, "ses_fail", "user", -40);
        // Archived sessions are not listed.
        Session(database, "ses_arch", -5, -5, "/tmp/HermesArch", archived: true);
        Message(database, "ses_arch", "user", -5);

        // A profile store in WAL mode whose writer closed. Hermes's SQLite removes the -wal and -shm on the last close; the
        // host library may keep them, so the checkpointed files are removed here.
        using (var profileDatabase = OpenCodeDatabase.Open(profilePath, create: true))
        {
            Sql(profileDatabase, "PRAGMA journal_mode=WAL");
            Schema(profileDatabase);
            Session(profileDatabase, "ses_profile", -10, -5, "/tmp/ProfileProject");
            Message(profileDatabase, "ses_profile", "user", -5);
            Sql(profileDatabase, "PRAGMA wal_checkpoint(TRUNCATE)");
        }
        File.Delete(profilePath + "-wal");
        File.Delete(profilePath + "-shm");

        var log = LogLine(-31, "INFO", "ses_tool", "agent.turn_context: conversation turn: session=ses_tool model=fixture-model msg='PRIVATE prompt'")
            + LogLine(-12, "WARNING", "ses_tool", "agent.conversation_loop: Retrying API call in 2.0s (attempt 1/3) PRIVATE error")
            + LogLine(-11, "INFO", "ses_tool", "agent.conversation_loop: API call #3: model=fixture-model provider=fixture in=42000 out=300 total=42300 latency=6.0s cache=40000/42000 (95%)")
            + LogLine(-41, "INFO", "ses_fail", "agent.turn_context: conversation turn: session=ses_fail model=fixture-model msg='PRIVATE prompt'")
            + LogLine(-30, "ERROR", "ses_fail", "agent.conversation_loop: API call failed after 3 retries. HTTP 429 PRIVATE")
            + "PRIVATE continuation line of a multi-line record\n";
        var logPath = Path.Combine(logs, "agent.log");
        File.WriteAllText(logPath, log);
        if (failed)
        {
            check(false, "Hermes fixture: SQL or log write failed");
            return;
        }
        var walGone = !File.Exists(profilePath + "-wal");

        var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
        var rows = tracker.Sample().Where(r => r.Source == TokenSource.Hermes).ToList();
        TokenReading? Row(string id) => rows.FirstOrDefault(r => r.SessionID == id);
        var work = Row("ses_tool");
        check(work is { Active: true, ActivityState: TokenActivityState.Tool, ToolName: "read_file", ToolCategory: ToolCategory.File,
                  CurrentTurnOutputTokens: null, Model: "fixture-model", Project: "HermesWork", ProjectPath: "/tmp/HermesWork",
                  Title: "Fix login flow", IsSubagent: false, Context.UsedTokens: 42_000, RecentOutputs.Count: 0 }
              && work.CurrentTurnStartedAt == now.AddSeconds(-30) && work.Id.EndsWith("hermes/state.db#ses_tool", StringComparison.Ordinal),
              "Hermes: an open turn running its second tool lost its state, tool, start, model, project, title or context, or counted the baseline");
        var speed = work?.SpeedMeasurement;
        check(speed is { Kind: TokenRateKind.RequestProcessing, OutputTokens: 300, RequestDurationMs: 6_000, RequestDurationIncludesRetries: true, Model: "fixture-model" }
              && speed.At == now.AddSeconds(-11),
              "Hermes: the agent.log API call line did not give out over latency, flagged with its retry");
        check(Row("ses_done") is { Active: false, ActivityState: TokenActivityState.Complete, Title: null, Project: "HermesDone", LastOutputTokens: null, Model: "session-model" },
              "Hermes: a finished turn is not complete, counted its baseline, or showed a title derived from the prompt");
        check(Row("ses_child") is { ActivityState: TokenActivityState.Input, Active: true, ToolName: "clarify", ToolCategory: ToolCategory.Question,
                  IsSubagent: true, ParentSessionID: "ses_tool", AgentID: "ses_child", Project: "HermesWork" },
              "Hermes: a delegated subagent asking the person is not waiting for input under its parent with the parent's project");
        var chain = Row("ses_long");
        check(chain is { ActivityState: TokenActivityState.Working, Active: true, Title: "Long refactor", Project: "HermesLong", IsSubagent: false }
              && chain.CurrentTurnStartedAt == now.AddSeconds(-200) && Row("ses_long_2") is null && chain.Id.EndsWith("#ses_long", StringComparison.Ordinal),
              "Hermes: a compression chain is not one row named after its first session, with the prompt from the ended segment");
        check(Row("ses_fail") is { ActivityState: TokenActivityState.Interrupted, Active: false } && Row("ses_arch") is null,
              "Hermes: a turn agent.log ended after failed retries stayed open, or an archived session was listed");
        check(walGone && Row("ses_profile") is { ActivityState: TokenActivityState.Working, Project: "ProfileProject" } profileRow
              && profileRow.Id.EndsWith("profiles/work/state.db#ses_profile", StringComparison.Ordinal),
              "Hermes: a profile's state.db without its -wal (writer closed) was not discovered or read");
        check(tracker.IsLog(path) && tracker.IsLog(profilePath) && !tracker.IsLog(Path.Combine(hermes, "hermes-agent", "state.db"))
              && !tracker.IsLog(path + "-wal") && !tracker.IsLog(logPath)
              && HermesLog.Root(Path.Combine("/srv", "hermes", "profiles", "coder")) == Path.Combine("/srv", "hermes")
              && HermesLog.Root(Path.Combine("/srv", "hermes")) == Path.Combine("/srv", "hermes"),
              "Hermes: state.db matching or the HERMES_HOME profile root is wrong");

        // The second tool returns and the turn completes; its 500 tokens are logged, but the turn began before the baseline.
        Message(database, "ses_tool", "tool", -4, result: "c2");
        Message(database, "ses_tool", "assistant", -2, "stop");
        Sql(database, "UPDATE sessions SET output_tokens = 1500, message_count = 5 WHERE id = 'ses_tool'");
        rows = [.. tracker.Sample().Where(r => r.Source == TokenSource.Hermes)];
        var completed = Row("ses_tool");
        check(!failed && completed is { ActivityState: TokenActivityState.Complete, Active: false, ToolName: null, LastOutputTokens: null }
              && completed.RecentOutputs.Select(e => e.Tokens).SequenceEqual([500]) && completed.RecentOutputs[0].At == now.AddSeconds(-2),
              "Hermes: a completed turn did not log its growth at the last message, or counted a turn seen only in part");
        // A new prompt starts a whole turn at zero.
        Message(database, "ses_tool", "user", -1.5);
        Sql(database, "UPDATE sessions SET message_count = 6 WHERE id = 'ses_tool'");
        rows = [.. tracker.Sample().Where(r => r.Source == TokenSource.Hermes)];
        check(!failed && Row("ses_tool") is { ActivityState: TokenActivityState.Working, CurrentTurnOutputTokens: 0 } opened
              && opened.CurrentTurnStartedAt == now.AddSeconds(-1.5),
              "Hermes: a new prompt did not open a turn at zero output");
        // Its answer: 120 tokens, its API call and Turn ended lines.
        Message(database, "ses_tool", "assistant", -0.5, "stop");
        Sql(database, "UPDATE sessions SET output_tokens = 1620, message_count = 7 WHERE id = 'ses_tool'");
        File.AppendAllText(logPath,
            LogLine(-0.6, "INFO", "ses_tool", "agent.conversation_loop: API call #4: model=fixture-model provider=fixture in=43000 out=120 total=43120 latency=2.0s")
            + LogLine(-0.4, "INFO", "ses_tool", "agent.conversation_loop: Turn ended: reason=text_response(finish_reason=stop) model=fixture-model api_calls=1/90 session=ses_tool"));
        rows = [.. tracker.Sample().Where(r => r.Source == TokenSource.Hermes)];
        check(!failed && Row("ses_tool") is { ActivityState: TokenActivityState.Complete, LastOutputTokens: 120, Context.UsedTokens: 43_000,
                  SpeedMeasurement: { TokensPerSecond: 60, RequestDurationIncludesRetries: false } } whole
              && whole.RecentOutputs.Select(e => e.Tokens).SequenceEqual([500, 120]),
              "Hermes: a whole turn's output, context or measured speed is wrong");
        check(rows.Count == 6 && !Encoding.UTF8.GetString(Json.Serialize(rows)).Contains("PRIVATE", StringComparison.Ordinal),
              "Hermes: a reading carried message, reasoning, argument, prompt or log text");
    }
}
