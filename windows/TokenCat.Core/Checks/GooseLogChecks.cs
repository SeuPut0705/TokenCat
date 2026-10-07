using System.Globalization;
using System.Text.Json;

namespace TokenCat;

/// GooseLogChecks.swift: a fixture database (synthetic metadata; every text field is a "PRIVATE" marker) — turn state, tool,
/// approval wait, ledger output, model, project, subagent, title rules, measured speed and an incremental update. The tables
/// are Goose's own `create_schema` DDL (crates/goose/src/session/session_manager.rs, schema version 16). Run from
/// `TrackerChecks.Run`; descriptions verbatim.
static class GooseLogChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), $"tokencat-goose-{Guid.NewGuid()}");
        try { Fixture(root, check); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { check(false, $"Goose fixture error: {error.Message}"); }
        finally
        {
            try { Directory.Delete(root, true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    static void Fixture(string root, Action<bool, string> check)
    {
        var now = DateTimeOffset.Parse("2026-10-04T06:00:00Z", CultureInfo.InvariantCulture);
        long Seconds(double offset) => now.AddSeconds(offset).ToUnixTimeSeconds();
        // SQLite's `datetime('now')` text, as Goose writes `updated_at` and `timestamp`.
        string Stamp(double offset) => now.AddSeconds(offset).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        string Json(object value) => JsonSerializer.Serialize(value);
        object Text() => new { type = "text", text = "PRIVATE_REPLY" };
        object Request(string id, string name) =>
            new { type = "toolRequest", id, toolCall = new { status = "success", value = new { name, arguments = new { command = "PRIVATE_CMD" } } } };
        object Response(string id) =>
            new { type = "toolResponse", id, toolResult = new { status = "success", value = new { content = new[] { new { type = "text", text = "PRIVATE_OUT" } }, isError = false } } };
        string Metadata(bool visible = true, int? output = null, int? elapsed = null, int? ttft = null)
        {
            var value = new Dictionary<string, object> { ["userVisible"] = visible, ["agentVisible"] = true };
            if (output is { } tokens)
            {
                var usage = new Dictionary<string, object> { ["outputTokens"] = tokens, ["inputTokens"] = 9_000 };
                if (elapsed is { } ms) usage["elapsedMs"] = ms;
                if (ttft is { } first) usage["timeToFirstTokenMs"] = first;
                value["usage"] = usage;
                value["inference"] = new { provider = "anthropic", requestedModel = "claude-fixture", resolvedModel = "claude-fixture-4" };
            }
            return Json(value);
        }

        var home = Path.Combine(root, "goose-home");
        var folder = Path.Combine(home, "AppData", "Roaming", "Block", "goose", "data", "sessions");
        var path = Path.Combine(folder, "sessions.db");
        Directory.CreateDirectory(folder);
        using var database = OpenCodeDatabase.Open(path, create: true);
        if (database is null)
        {
            check(false, "Goose fixture: database not created");
            return;
        }
        var failed = false;
        void Sql(string sql, params object?[] values) => failed |= !database.Query(sql, values, _ => { });
        Sql("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
                user_set_name BOOLEAN DEFAULT FALSE, session_type TEXT NOT NULL DEFAULT 'user', working_dir TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, extension_data TEXT DEFAULT '{}',
                total_tokens INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                accumulated_total_tokens INTEGER, accumulated_input_tokens INTEGER, accumulated_output_tokens INTEGER,
                accumulated_cache_read_tokens INTEGER, accumulated_cache_write_tokens INTEGER, accumulated_cost REAL, schedule_id TEXT,
                recipe_json TEXT, user_recipe_values_json TEXT, provider_name TEXT, model_config_json TEXT,
                goose_mode TEXT NOT NULL DEFAULT 'auto', archived_at TIMESTAMP, project_id TEXT, parent_session_id TEXT)
            """);
        Sql("""
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT, session_id TEXT NOT NULL REFERENCES sessions(id),
                role TEXT NOT NULL, content_json TEXT NOT NULL, created_timestamp INTEGER NOT NULL, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                tokens INTEGER, metadata_json TEXT)
            """);
        Sql("""
            CREATE TABLE usage_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                created_timestamp INTEGER NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER,
                cache_read_tokens INTEGER, cache_write_tokens INTEGER, cost REAL, cost_source TEXT, is_compaction INTEGER DEFAULT 0)
            """);
        void Session(string id, string name, string directory, double updated, bool userSet = false, string type = "user",
            string provider = "anthropic", string? parent = null, bool archived = false) =>
            Sql("""
                INSERT INTO sessions (id, name, user_set_name, session_type, working_dir, created_at, updated_at, provider_name,
                    model_config_json, archived_at, parent_session_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, id, name, userSet ? 1L : 0L, type, directory, Stamp(-3_000), Stamp(updated), provider,
                Json(new { model_name = "fixture-session-model", temperature = (double?)null, max_tokens = (int?)null, toolshim = false, toolshim_model = (string?)null }),
                archived ? Stamp(updated) : null, parent);
        void Message(string session, string role, double at, object[] content, string? meta = null) =>
            Sql("INSERT INTO messages (message_id, session_id, role, content_json, created_timestamp, timestamp, metadata_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
                $"msg_{session}_{Guid.NewGuid()}", session, role, Json(content), Seconds(at), Stamp(at), meta ?? Metadata());
        void Ledger(string session, double at, int output, int input = 9_000, string? source = null) =>
            Sql("INSERT INTO usage_ledger (session_id, created_timestamp, model, input_tokens, output_tokens, total_tokens, cost_source) VALUES (?, ?, ?, ?, ?, ?, ?)",
                session, Seconds(at), source is null ? "claude-fixture-4" : null, (long)input, (long)output, (long)(input + output), source);

        // A working turn: an agent-only turn-context message does not reopen it, one shell call returned, the next runs.
        Session("ses_work", "Fix flaky\nlogin test", "/tmp/GooseWork", -10);
        Message("ses_work", "user", -40, [new { type = "text", text = "PRIVATE_PROMPT" }]);
        Message("ses_work", "user", -39, [new { type = "text", text = "PRIVATE_CONTEXT" }], Metadata(visible: false));
        Message("ses_work", "assistant", -30, [Text(), Request("t1", "shell")], Metadata(output: 120, elapsed: 3_000, ttft: 400));
        Ledger("ses_work", -30, 120);
        Message("ses_work", "user", -20, [Response("t1")]);
        Message("ses_work", "assistant", -10, [Request("t2", "shell")], Metadata(output: 30, elapsed: 1_500, ttft: 200));
        Ledger("ses_work", -10, 30, input: 9_500);
        // A finished turn; the ACP placeholder name is no title, and the backfilled carried_forward row is no model call.
        Session("ses_done", "New Chat", "/tmp/GooseDone", -100, provider: "openai");
        Message("ses_done", "user", -200, [new { type = "text", text = "PRIVATE_PROMPT" }]);
        Message("ses_done", "assistant", -150, [new { type = "thinking", thinking = "PRIVATE", signature = "PRIVATE" }, Text()],
            Metadata(output: 400, elapsed: 8_000));
        Ledger("ses_done", -150, 400);
        Ledger("ses_done", -100, 999, source: "carried_forward");
        // A subagent whose shell call waits for the person's approval.
        Session("ses_ask", "Delegated task", "/tmp/GooseWork", -25, type: "sub_agent", parent: "ses_work");
        Message("ses_ask", "user", -28, [new { type = "text", text = "PRIVATE_TASK" }]);
        Message("ses_ask", "assistant", -26, [Request("t9", "developer__shell")]);
        Message("ses_ask", "assistant", -25, [new { type = "actionRequired", data = new { actionType = "toolConfirmation", id = "t9",
            toolName = "developer__shell", arguments = new { command = "PRIVATE" }, prompt = "PRIVATE" } }]);
        // claude-code names a session from the first prompt's first words (no title until the person renames it) and logs its
        // own tokens, which the Claude Code reader counts: its finished turn and new prompt report no output or speed here.
        Session("ses_cli", "PRIVATE fix the bug", "/tmp/GooseCli", -3, provider: "claude-code");
        Message("ses_cli", "user", -50, [new { type = "text", text = "PRIVATE_PROMPT" }]);
        Message("ses_cli", "assistant", -45, [Text()], Metadata(output: 70, elapsed: 700));
        Ledger("ses_cli", -45, 70, input: 7_000);
        Message("ses_cli", "user", -3, [new { type = "text", text = "PRIVATE_PROMPT" }]);
        // A fresh prompt on a model provider opens a turn at zero output.
        Session("ses_new", "New Chat", "/tmp/GooseNew", -4);
        Message("ses_new", "user", -4, [new { type = "text", text = "PRIVATE_PROMPT" }]);
        // A provider error ends the turn.
        Session("ses_err", "Broken request", "/tmp/GooseErr", -60);
        Message("ses_err", "user", -70, [new { type = "text", text = "PRIVATE_PROMPT" }]);
        Message("ses_err", "assistant", -60, [new { type = "error", kind = "authentication", message = "PRIVATE_ERR" }]);
        // Archived sessions are not listed.
        Session("ses_old", "Old work", "/tmp/GooseOld", -1, archived: true);
        Message("ses_old", "user", -1, [new { type = "text", text = "PRIVATE_PROMPT" }]);
        if (failed)
        {
            check(false, "Goose fixture: SQL failed");
            return;
        }

        var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
        var rows = tracker.Sample().Where(r => r.Source == TokenSource.Goose).ToList();
        TokenReading? Row(string id) => rows.FirstOrDefault(r => r.SessionID == id);
        var work = Row("ses_work");
        check(work is { Active: true, ActivityState: TokenActivityState.Tool, ToolName: "shell", ToolCategory: ToolCategory.Command, CurrentTurnOutputTokens: 150,
                  Model: "claude-fixture-4", Project: "GooseWork", ProjectPath: "/tmp/GooseWork", Context.UsedTokens: 9_500, IsSubagent: false,
                  Title: "Fix flaky login test" }
              && work.CurrentTurnStartedAt == now.AddSeconds(-40) && work.Id.EndsWith("sessions.db#ses_work", StringComparison.Ordinal),
              "Goose: a working turn running shell lost its state, turn start, ledger output, model, project, context or generated title");
        var speed = work?.SpeedMeasurement;
        check(speed is { Kind: TokenRateKind.RequestProcessing, OutputTokens: 30, RequestDurationMs: 1_500, TtftMs: 200, TokensPerSecond: 20, Model: "claude-fixture-4" }
              && speed.At == now.AddSeconds(-10),
              "Goose: measured speed is not the newest reply's output tokens over its recorded elapsedMs");
        var done = Row("ses_done");
        check(done is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 400, CurrentTurnStartedAt: null,
                  CurrentTurnOutputTokens: null, SpeedMeasurement.TokensPerSecond: 50, Title: null }
              && done.MeasurementAt == now.AddSeconds(-150) && done.RecentOutputs.Select(e => e.Tokens).SequenceEqual([400]),
              "Goose: a finished turn is not complete with its output and speed, the carried_forward row counted, or the placeholder title showed");
        check(Row("ses_ask") is { ActivityState: TokenActivityState.Input, Active: true, ToolName: "developer__shell", ToolCategory: ToolCategory.Command,
                  IsSubagent: true, ParentSessionID: "ses_work", AgentID: "ses_ask", Title: null, Model: "fixture-session-model" },
              "Goose: a subagent waiting for tool approval is not input under its parent, or showed its placeholder title");
        var fresh = Row("ses_new");
        check(fresh is { ActivityState: TokenActivityState.Working, Active: true, CurrentTurnOutputTokens: 0 }
              && fresh.CurrentTurnStartedAt == now.AddSeconds(-4) && Row("ses_cli") is { Title: null },
              "Goose: a fresh prompt did not open a turn at zero output, or a name cut from the prompt showed as title");
        var cli = Row("ses_cli");
        check(cli is { ActivityState: TokenActivityState.Working, Active: true, CurrentTurnOutputTokens: null, LastOutputTokens: null, LastOutputAt: null,
                  RecentOutputs.Count: 0, SpeedMeasurement: null, Context.UsedTokens: 7_000 }
              && cli.CurrentTurnStartedAt == now.AddSeconds(-3) && done is { LastOutputTokens: 400, SpeedMeasurement: not null },
              "Goose: a CLI or ACP agent provider's session reported output or speed its own log already counts, or a model provider's did not");
        check(Row("ses_err") is { ActivityState: TokenActivityState.Interrupted, Active: false, Title: "Broken request" }
              && rows.Count == 6 && Row("ses_old") is null,
              "Goose: an error reply did not end the turn as interrupted, or archived sessions were listed");
        check(!JsonSerializer.Serialize(rows).Contains("PRIVATE", StringComparison.Ordinal),
              "Goose: message text, tool arguments or a prompt-cut name leaked into a reading");
        check(tracker.IsLog(path) && !tracker.IsLog(Path.Combine(folder, "other.db")) && !tracker.IsLog(path + "-wal")
              && tracker.WakesSampling(path + "-wal"),
              "Goose: database file matching is wrong");
        var goose = TokenProvider.All.First(provider => provider.Source == TokenSource.Goose);
        var custom = Path.GetFullPath(Path.Combine(root, "goose-root"));
        check(goose.Roots(home, key => key == "GOOSE_PATH_ROOT" ? custom : null)
                  .SequenceEqual([Path.Combine(custom, "data", "sessions"), folder])
              && goose.Roots(home, _ => null).SequenceEqual([folder]),
              "Goose: roots are not $GOOSE_PATH_ROOT/data/sessions and the default data folder's sessions");
        check(GooseLog.Title("Fix it", false, "codex-acp", false) is null
              && GooseLog.Title("Fix it", true, "codex-acp", false) == "Fix it"
              && GooseLog.Title("Release notes", false, "cursor-agent", true) == "Release notes"
              && GooseLog.Title("CLI Session", false, null, false) is null
              && GooseLog.Category("github__create_issue") == ToolCategory.Mcp && GooseLog.Category("delegate") == ToolCategory.Agent
              && GooseLog.Category("developer__text_editor") == ToolCategory.File,
              "Goose: title or tool category rules are wrong");

        // The shell step returns and a reply ends the turn; the person renames the claude-code session.
        Message("ses_work", "user", -6, [Response("t2")]);
        Message("ses_work", "assistant", -2, [Text()], Metadata(output: 50, elapsed: 1_000));
        Ledger("ses_work", -2, 50);
        Sql("UPDATE sessions SET updated_at = ? WHERE id = 'ses_work'", Stamp(-2));
        Sql("UPDATE sessions SET name = 'Renamed by me', user_set_name = TRUE, updated_at = ? WHERE id = 'ses_cli'", Stamp(-1));
        var updated = tracker.Sample().Where(r => r.Source == TokenSource.Goose).ToList();
        var finished = updated.FirstOrDefault(r => r.SessionID == "ses_work");
        check(!failed && finished is { ActivityState: TokenActivityState.Complete, Active: false, LastOutputTokens: 200, ToolName: null,
                  SpeedMeasurement.TokensPerSecond: 50 }
              && finished.RecentOutputs.Select(e => e.Tokens).SequenceEqual([120, 30, 50])
              && updated.FirstOrDefault(r => r.SessionID == "ses_cli")?.Title == "Renamed by me",
              "Goose: a finished step or a rename was not picked up incrementally, or the turn total and speed are wrong");
    }
}
