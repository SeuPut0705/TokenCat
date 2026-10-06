using System.Text.Json;

namespace TokenCat;

/// OpenCodeLogChecks.swift: a fixture database (synthetic metadata, no transcript text) — turn state, tool, input wait, token
/// totals, model, project, subagent, session title, measured speed and an incremental update. Run from `TrackerChecks.Run`;
/// descriptions verbatim.
static class OpenCodeLogChecks
{
    public static void Run(string root, Action<bool, string> check)
    {
        var now = DateTimeOffset.Parse("2026-10-04T06:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
        long Ms(double seconds) => now.AddSeconds(seconds).ToUnixTimeMilliseconds();
        string Json(object value) => JsonSerializer.Serialize(value);
        string Assistant(string parent, double created, double? completed = null, string? finish = null, int output = 0, int reasoning = 0,
            string cwd = "", string agent = "build")
        {
            var time = new Dictionary<string, object> { ["created"] = Ms(created) };
            if (completed is { } done) time["completed"] = Ms(done);
            var value = new Dictionary<string, object>
            {
                ["role"] = "assistant", ["parentID"] = parent, ["modelID"] = "fixture-model", ["providerID"] = "fixture", ["agent"] = agent,
                ["path"] = new { cwd, root = cwd }, ["time"] = time,
                ["tokens"] = new { input = 1_000, output, reasoning, cache = new { read = 5_000, write = 0 } },
            };
            if (finish is not null) value["finish"] = finish;
            return Json(value);
        }
        string User(double created, int padding = 0) =>
            Json(new { role = "user", time = new { created = Ms(created) }, agent = "build", model = new { providerID = "fixture", modelID = "fixture-model" },
                       summary = new { diffs = new[] { new string('x', padding) } } });

        var home = Path.Combine(root, "opencode-home");
        var folder = Path.Combine(home, ".local", "share", "opencode");
        var path = Path.Combine(folder, "opencode.db");
        Directory.CreateDirectory(folder);
        using var database = OpenCodeDatabase.Open(path, create: true);
        if (database is null)
        {
            check(false, "OpenCode fixture: database not created");
            return;
        }
        var failed = false;
        void Sql(string sql, params object?[] values) => failed |= !database.Query(sql, values, _ => { });
        Sql("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT NOT NULL, agent TEXT, model TEXT, time_updated INTEGER NOT NULL, time_archived INTEGER)");
        Sql("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)");
        Sql("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)");
        // The title defaults to OpenCode's placeholder, which is no title.
        void Session(string id, string directory, double updated, string? parent = null, string? title = null, string agent = "build", bool archived = false) =>
            Sql("INSERT INTO session VALUES (?, ?, ?, ?, ?, ?, ?, ?)", id, parent, directory,
                title ?? $"{(parent is null ? "New" : "Child")} session - 2026-10-04T05:00:00.000Z", agent,
                Json(new { id = "session-model", providerID = "fixture" }), Ms(updated), archived ? Ms(updated) : null);
        void Message(string id, string session, double created, double updated, string data) =>
            Sql("INSERT OR REPLACE INTO message VALUES (?, ?, ?, ?, ?)", id, session, Ms(created), Ms(updated), data);
        void Part(string id, string message, string session, double updated, object data) =>
            Sql("INSERT OR REPLACE INTO part VALUES (?, ?, ?, ?, ?, ?)", id, message, session, Ms(updated), Ms(updated), Json(data));
        // A working turn: one step ended in tool calls, the next runs bash. Its 320 tokens over created → last generated part
        // (the write tool's execution start, -12 s, after reasoning and text) are 6 s: 53.3 tok/s.
        Session("ses_work", "/tmp/WorkProject", -2, title: "Fix flaky\nlogin test");
        Message("u1", "ses_work", -20, -20, User(-20));
        Message("a1", "ses_work", -18, -10, Assistant("u1", -18, -10, "tool-calls", 300, 20, "/tmp/WorkProject"));
        Part("p1", "a1", "ses_work", -15, new { type = "reasoning", time = new { start = Ms(-17), end = Ms(-15) } });
        Part("p2", "a1", "ses_work", -13, new { type = "text", time = new { start = Ms(-14), end = Ms(-13) } });
        Part("p3", "a1", "ses_work", -11, new { type = "tool", tool = "write", state = new { status = "completed", time = new { start = Ms(-12), end = Ms(-11) } } });
        Message("a2", "ses_work", -9, -9, Assistant("u1", -9, cwd: "/tmp/WorkProject"));
        Part("p4", "a2", "ses_work", -2, new { type = "tool", tool = "bash", state = new { status = "running", time = new { start = Ms(-3) } } });
        // A finished turn waiting for the next prompt: 500 tokens over 40 s.
        Session("ses_done", "/tmp/DoneProject", -50);
        Message("u2", "ses_done", -100, -100, User(-100));
        Message("b1", "ses_done", -90, -50, Assistant("u2", -90, -50, "stop", 500, cwd: "/tmp/DoneProject"));
        Part("p5", "b1", "ses_done", -50, new { type = "text", time = new { start = Ms(-60), end = Ms(-50) } });
        // A subagent asking the person a question.
        Session("ses_ask", "/tmp/WorkProject", -25, parent: "ses_work", agent: "explore");
        Message("u3", "ses_ask", -30, -30, User(-30));
        Message("c1", "ses_ask", -25, -25, Assistant("u3", -25, cwd: "/tmp/WorkProject", agent: "explore"));
        Part("p6", "c1", "ses_ask", -24, new { type = "tool", tool = "question", state = new { status = "running", time = new { start = Ms(-24) } } });
        // A prompt whose body is over the 64 KB cap (a summary with diffs) is never loaded, yet opens a turn.
        Session("ses_big", "/tmp/BigProject", -5);
        Message("u4", "ses_big", -5, -5, User(-5, padding: 70_000));
        // Archived sessions are not listed.
        Session("ses_old", "/tmp/OldProject", -1, archived: true);
        Message("u5", "ses_old", -1, -1, User(-1));
        if (failed)
        {
            check(false, "OpenCode fixture: SQL failed");
            return;
        }

        var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
        var rows = tracker.Sample().Where(r => r.Source == TokenSource.OpenCode).ToList();
        TokenReading? Row(string id) => rows.FirstOrDefault(r => r.SessionID == id);
        var work = Row("ses_work");
        check(work is { Active: true, ActivityState: TokenActivityState.Tool, ToolName: "bash", ToolCategory: ToolCategory.Command, CurrentTurnOutputTokens: 320,
                  Model: "fixture-model", Project: "WorkProject", ProjectPath: "/tmp/WorkProject", Context.UsedTokens: 6_000, IsSubagent: false,
                  Title: "Fix flaky login test" }
              && work.CurrentTurnStartedAt == now.AddSeconds(-20) && work.Id.EndsWith("opencode.db#ses_work", StringComparison.Ordinal),
              "OpenCode: a working turn running bash lost its state, turn output, model, project, context or generated title");
        var speed = work?.SpeedMeasurement;
        check(speed is { Kind: TokenRateKind.RequestProcessing, OutputTokens: 320, RequestDurationMs: 6_000, Model: "fixture-model" }
              && speed.TokensPerSecond is { } rate && Math.Abs(rate - 320.0 / 6) < 0.001 && speed.At == now.AddSeconds(-10),
              "OpenCode: measured speed is not output + reasoning over created → last generated part");
        var done = Row("ses_done");
        check(done is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 500, CurrentTurnStartedAt: null,
                  CurrentTurnOutputTokens: null, Project: "DoneProject", SpeedMeasurement.TokensPerSecond: 12.5, Title: null }
              && done.MeasurementAt == now.AddSeconds(-50),
              "OpenCode: a finished turn waiting for input is not complete with its output and speed, or the placeholder title showed");
        check(Row("ses_ask") is { ActivityState: TokenActivityState.Input, Active: true, ToolCategory: ToolCategory.Question, IsSubagent: true,
                  ParentSessionID: "ses_work", AgentID: "ses_ask", AgentRole: "explore", Title: null },
              "OpenCode: a subagent asking a question is not waiting for input under its parent, or showed the child placeholder title");
        var big = Row("ses_big");
        check(big is { ActivityState: TokenActivityState.Working, Active: true, CurrentTurnOutputTokens: 0, Model: "session-model", Project: "BigProject" }
              && big.CurrentTurnStartedAt == now.AddSeconds(-5),
              "OpenCode: an oversized prompt did not open a turn, or the session model was not the fallback");
        check(rows.Count == 4 && Row("ses_old") is null && rows.SelectMany(r => r.RecentOutputs).Sum(e => e.Tokens) == 820,
              "OpenCode: archived sessions listed, or token totals are not the completed messages' output + reasoning");
        check(tracker.IsLog(path) && tracker.IsLog(Path.Combine(folder, "opencode-beta.db"))
              && !tracker.IsLog(Path.Combine(folder, "other.db")) && !tracker.IsLog(path + "-wal"),
              "OpenCode: database file matching is wrong");
        check(TokenProvider.OpenCodeDatabasePath(home, key => key == "OPENCODE_DB" ? "custom.db" : null) == Path.GetFullPath(Path.Combine(folder, "custom.db"))
              && TokenProvider.OpenCodeDatabasePath(home, key => key == "OPENCODE_DB" ? ":memory:" : null) is null,
              "OpenCode: OPENCODE_DB was not resolved like OpenCode (relative to its data folder; :memory: is no file)");

        // A failed request whose error holds a large gateway page (over the 64 KB body cap) is an assistant message, not a prompt.
        Session("ses_err", "/tmp/ErrProject", -3);
        Message("u6", "ses_err", -8, -8, User(-8));
        Message("e1", "ses_err", -6, -3, Json(new
        {
            error = new { name = "APIError", data = new { responseBody = string.Concat(Enumerable.Repeat("<html>", 15_000)) } },
            role = "assistant", parentID = "u6", modelID = "fixture-model", time = new { created = Ms(-6), completed = Ms(-3) },
        }));
        check(!failed && tracker.Sample().FirstOrDefault(r => r.SessionID == "ses_err") is { ActivityState: TokenActivityState.Interrupted, Active: false },
              "OpenCode: an assistant row over 64 KB was read as the person's prompt instead of a failed request");

        // Two steps at int.MaxValue each: LINQ's checked Sum threw on every sample and froze every client's tokens.
        Session("ses_huge", "/tmp/HugeProject", -3);
        Message("u7", "ses_huge", -8, -8, User(-8));
        Message("h1", "ses_huge", -7, -6, Assistant("u7", -7, -6, "tool-calls", int.MaxValue, cwd: "/tmp/HugeProject"));
        Message("h2", "ses_huge", -5, -3, Assistant("u7", -5, -3, "stop", int.MaxValue, cwd: "/tmp/HugeProject"));
        TokenReading? huge = null;
        try { huge = tracker.Sample().FirstOrDefault(r => r.SessionID == "ses_huge"); } catch (OverflowException) { }
        check(huge is { LastOutputTokens: int.MaxValue },
              "OpenCode: a turn total past int.MaxValue threw instead of holding at the maximum");

        // The bash step finishes the turn: the cached message row is replaced because its time_updated moved.
        Message("a2", "ses_work", -9, -1, Assistant("u1", -9, -1, "stop", 80, cwd: "/tmp/WorkProject"));
        Part("p4", "a2", "ses_work", -4, new { type = "tool", tool = "bash", state = new { status = "completed", time = new { start = Ms(-3), end = Ms(-4) } } });
        Part("p7", "a2", "ses_work", -1, new { type = "text", time = new { start = Ms(-2), end = Ms(-1) } });
        Sql("UPDATE session SET time_updated = ?, title = 'Renamed: login fix' WHERE id = 'ses_work'", Ms(-1));
        var finished = tracker.Sample().FirstOrDefault(r => r.SessionID == "ses_work");
        check(!failed && finished is { ActivityState: TokenActivityState.Complete, Active: false, LastOutputTokens: 400, ToolName: null, SpeedMeasurement.TokensPerSecond: 10,
                  Title: "Renamed: login fix" }
              && finished.RecentOutputs.Select(e => e.Tokens).SequenceEqual([320, 80]),
              "OpenCode: a finished step or the renamed title was not picked up incrementally, or the turn total and speed are wrong");
        check(OpenCodeLog.Title("New session - 2026-10-04T05:00:00.000Z") is null && OpenCodeLog.Title("Child session - 2026-10-04T05:00:00.000Z") is null
              && OpenCodeLog.Title("New session - draft") == "New session - draft" && OpenCodeLog.Title("   ") is null,
              "OpenCode: only the exact placeholder (prefix and ISO time) is no title");
    }
}
