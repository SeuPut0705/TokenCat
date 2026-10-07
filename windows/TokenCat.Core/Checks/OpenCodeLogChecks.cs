using System.Text;
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
        var opencodeApp = OpenCodeApp.All[0];
        check(opencodeApp.DatabasePath(home, key => key == "OPENCODE_DB" ? "custom.db" : null) == Path.GetFullPath(Path.Combine(folder, "custom.db"))
              && opencodeApp.DatabasePath(home, key => key == "OPENCODE_DB" ? ":memory:" : null) is null,
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
        RunStores(root, now, check);
        // The same v2 fixture read as an OS SQLite without JSON functions (an older winsqlite3) would: the rows parsed in memory.
        OpenCodeLog.AvoidJsonFunctions = true;
        try
        {
            var parsedFailures = 0;
            RunStores(Path.Combine(root, "parsed"), now, (passed, _) => { if (!passed) parsedFailures++; });
            check(parsedFailures == 0, "OpenCode v2: rows read without SQLite's JSON functions differ from rows read with them");
        }
        finally { OpenCodeLog.AvoidJsonFunctions = false; }
    }

    /// A fixture database: statements with text, integer or null values; `Failed` once one did not run.
    sealed class Fixture : IDisposable
    {
        readonly OpenCodeDatabase? database;
        public bool Failed { get; private set; }

        public Fixture(string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            database = OpenCodeDatabase.Open(path, create: true);
            Failed = database is null;
        }

        public void Run(string sql, params object?[] values) => Failed |= database?.Query(sql, values, _ => { }) != true;

        public void Dispose() => database?.Dispose();
    }

    /// OpenCodeLogChecks.swift `runOpenCodeStoreChecks`: OpenCode v2 (`session_message` rows, sessions in `session_v2`), a
    /// database holding both stores, and the apps built on OpenCode's store (Kilo Code, MiMo Code). Synthetic metadata; every
    /// text field says "PRIVATE" and must never surface.
    static void RunStores(string root, DateTimeOffset now, Action<bool, string> check)
    {
        long Ms(double seconds) => now.AddSeconds(seconds).ToUnixTimeMilliseconds();
        string Json(object value) => JsonSerializer.Serialize(value);
        bool Leaks(IEnumerable<TokenReading> rows) => Encoding.UTF8.GetString(TokenCat.Json.Serialize(rows.ToList())).Contains("PRIVATE", StringComparison.Ordinal);
        var model = new { id = "fixture-model", providerID = "fixture" };
        // v2 rows: `data` without `type` and `id` (they are columns).
        string Step(double created, double? completed = null, double? streamed = null, string? finish = null, int output = 0, int reasoning = 0,
            string agent = "build", object[]? content = null)
        {
            var time = new Dictionary<string, object> { ["created"] = Ms(created) };
            if (completed is { } done) time["completed"] = Ms(done);
            if (streamed is { } end) time["streamed"] = Ms(end);
            var value = new Dictionary<string, object> { ["agent"] = agent, ["model"] = model, ["time"] = time, ["content"] = content ?? [] };
            if (finish is not null)
            {
                value["finish"] = finish;
                value["cost"] = 0.01;
                value["tokens"] = new { input = 1_000, output, reasoning, cache = new { read = 5_000, write = 0 } };
            }
            return Json(value);
        }
        string Prompt(double created) => Json(new { time = new { created = Ms(created) }, text = "PRIVATE prompt", files = Array.Empty<object>(), agents = Array.Empty<object>() });
        string Idle(double created, string outcome) => Json(new { time = new { created = Ms(created) }, outcome });
        object Tool(string name, string status, double ran) =>
            new { type = "tool", id = $"call-{name}", name, state = new { status, input = new { command = "PRIVATE" } }, time = new { created = Ms(ran - 1), ran = Ms(ran) } };
        object text = new { type = "text", text = "PRIVATE reply" };
        object Thought(double created, double completed) => new { type = "reasoning", text = "PRIVATE thought", time = new { created = Ms(created), completed = Ms(completed) } };
        // v1 rows, for the stores beside v2 and for Kilo Code and MiMo Code.
        string V1Assistant(string parent, double created, double? completed = null, string? finish = null, int output = 0)
        {
            var time = new Dictionary<string, object> { ["created"] = Ms(created) };
            if (completed is { } done) time["completed"] = Ms(done);
            var value = new Dictionary<string, object>
            {
                ["role"] = "assistant", ["parentID"] = parent, ["modelID"] = "fixture-model", ["providerID"] = "fixture", ["agent"] = "build", ["time"] = time,
                ["tokens"] = new { input = 1_000, output, reasoning = 0, cache = new { read = 5_000, write = 0 } },
            };
            if (finish is not null) value["finish"] = finish;
            return Json(value);
        }
        string V1User(double created) => Json(new { role = "user", time = new { created = Ms(created) }, agent = "build" });
        string[] v1Tables =
        [
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
            "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
        ];
        const string V2Table = "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)";
        const string SessionColumns = "(id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT, agent TEXT, model TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER)";
        void Session(Fixture fixture, string table, string id, string directory, string? title, double updated, string? parent = null, string agent = "build") =>
            fixture.Run($"INSERT OR REPLACE INTO {table} VALUES (?, 'prj', ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
                id, parent, id, directory, title, agent, Json(model), Ms(updated - 60), Ms(updated));
        long seq = 0;
        void V2(Fixture fixture, string id, string session, string type, double created, double updated, string data, long? fixedSeq = null)
        {
            seq++;
            fixture.Run("INSERT OR REPLACE INTO session_message VALUES (?, ?, ?, ?, ?, ?, ?)", id, session, type, fixedSeq ?? seq, Ms(created), Ms(updated), data);
        }
        void V1(Fixture fixture, string id, string session, double created, double updated, string data) =>
            fixture.Run("INSERT OR REPLACE INTO message VALUES (?, ?, ?, ?, ?)", id, session, Ms(created), Ms(updated), data);
        TokenReading? Row(IEnumerable<TokenReading> rows, string id) => rows.FirstOrDefault(r => r.SessionID == id);

        // v2 only, as OpenCode's v2 builds write it.
        var v2Home = Path.Combine(root, "opencode-v2-home");
        using var store = new Fixture(Path.Combine(v2Home, ".local", "share", "opencode", "opencode.db"));
        store.Run($"CREATE TABLE session_v2 {SessionColumns}");
        store.Run(V2Table);
        // A working turn: a step that streamed for 6 s (320 tokens, 53.3 tok/s) and called write, then a step running bash.
        Session(store, "session_v2", "ses_v2work", "/tmp/WorkV2", "Fix flaky\nlogin test", -20);
        V2(store, "w1", "ses_v2work", "user", -20, -20, Prompt(-20));
        V2(store, "w2", "ses_v2work", "assistant", -18, -10,
            Step(-18, -10, -12, "tool-calls", 300, 20, content: [Thought(-17, -15), text, Tool("write", "completed", -12)]));
        var w3 = seq + 1;
        V2(store, "w3", "ses_v2work", "assistant", -9, -2, Step(-9, content: [Tool("bash", "running", -3)]));
        // A subagent asking the person a question.
        Session(store, "session_v2", "ses_v2ask", "/tmp/WorkV2", null, -30, parent: "ses_v2work", agent: "explore");
        V2(store, "q1", "ses_v2ask", "user", -30, -30, Prompt(-30));
        V2(store, "q2", "ses_v2ask", "assistant", -25, -24, Step(-25, agent: "explore", content: [Tool("question", "running", -24)]));
        // A turn an idle marker ended (500 tokens over a 40 s step that ran no tool); the session row was last written 2 h ago.
        Session(store, "session_v2", "ses_v2done", "/tmp/DoneV2", null, -7_200);
        V2(store, "d1", "ses_v2done", "user", -100, -100, Prompt(-100));
        V2(store, "d2", "ses_v2done", "assistant", -90, -50, Step(-90, -50, finish: "stop", output: 500, content: [text]));
        V2(store, "d3", "ses_v2done", "idle", -49, -49, Idle(-49, "succeeded"));
        // A turn the person interrupted between steps.
        Session(store, "session_v2", "ses_v2stop", "/tmp/StopV2", null, -40);
        V2(store, "s1", "ses_v2stop", "user", -40, -40, Prompt(-40));
        V2(store, "s2", "ses_v2stop", "assistant", -38, -35, Step(-38, -35, finish: "tool-calls", output: 10, content: [text]));
        V2(store, "s3", "ses_v2stop", "idle", -34, -34, Idle(-34, "interrupted"));
        if (store.Failed)
        {
            check(false, "OpenCode v2 fixture: SQL failed");
            return;
        }

        var tracker = new TokenTracker(v2Home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
        var rows = tracker.Sample().Where(r => r.Source == TokenSource.OpenCode).ToList();
        var work = Row(rows, "ses_v2work");
        check(work is { Active: true, ActivityState: TokenActivityState.Tool, ToolName: "bash", ToolCategory: ToolCategory.Command, CurrentTurnOutputTokens: 320,
                  Model: "fixture-model", Project: "WorkV2", Context.UsedTokens: 6_000, Title: "Fix flaky login test", ClientName: null, IsSubagent: false,
                  SpeedMeasurement: { RequestDurationMs: 6_000, OutputTokens: 320 } }
              && work.CurrentTurnStartedAt == now.AddSeconds(-20) && work.SpeedMeasurement.At == now.AddSeconds(-10),
              "OpenCode v2: a working turn running bash lost its state, turn output, model, project, context, title or streamed speed");
        check(Row(rows, "ses_v2ask") is { ActivityState: TokenActivityState.Input, Active: true, ToolCategory: ToolCategory.Question, IsSubagent: true,
                  ParentSessionID: "ses_v2work", AgentRole: "explore", Title: null },
              "OpenCode v2: a subagent asking a question is not waiting for input under its parent");
        var done = Row(rows, "ses_v2done");
        check(done is { ActivityState: TokenActivityState.Complete, Active: false, LastOutputTokens: 500, SpeedMeasurement.TokensPerSecond: 12.5,
                  Project: "DoneV2", Title: null }
              && done.MeasurementAt == now.AddSeconds(-50)
              && Row(rows, "ses_v2stop") is { ActivityState: TokenActivityState.Interrupted, Active: false, LastOutputTokens: null },
              "OpenCode v2: a turn ended by an idle marker is not complete with its output and speed, or an interrupted one is not interrupted");
        check(rows.Count == 4 && !Leaks(rows) && rows.SelectMany(r => r.RecentOutputs).Sum(e => e.Tokens) == 830,
              "OpenCode v2: rows leaked text, or sessions were missed or listed twice");

        // The bash step ends the turn (its stream ended at -1 s: 80 tokens over 8 s); a prompt reopens the finished session
        // and a second one sent mid-turn joins that turn. Neither session row is written.
        V2(store, "w3", "ses_v2work", "assistant", -9, -1,
            Step(-9, -1, -1, "stop", 80, content: [Tool("bash", "completed", -3), text]), fixedSeq: w3);
        V2(store, "d4", "ses_v2done", "user", -3, -3, Prompt(-3));
        V2(store, "d5", "ses_v2done", "assistant", -2, -2, Step(-2, content: [text]));
        V2(store, "d6", "ses_v2done", "user", -1, -1, Prompt(-1));
        var next = tracker.Sample().Where(r => r.Source == TokenSource.OpenCode).ToList();
        check(!store.Failed && Row(next, "ses_v2work") is { ActivityState: TokenActivityState.Complete, Active: false, LastOutputTokens: 400, ToolName: null,
                  SpeedMeasurement.TokensPerSecond: 10 } finished
              && finished.RecentOutputs.Select(e => e.Tokens).SequenceEqual([320, 80]),
              "OpenCode v2: a finished step was not picked up incrementally, or its turn total and streamed speed are wrong");
        check(Row(next, "ses_v2done") is { ActivityState: TokenActivityState.Working, Active: true, CurrentTurnOutputTokens: 0 } reopened
              && reopened.CurrentTurnStartedAt == now.AddSeconds(-3),
              "OpenCode v2: messages written without moving the session's time_updated were missed, or a prompt sent mid-turn did not join it");

        // Both stores: a database migrated to v2 keeps its v1 tables, and its sessions are copied under the same ids.
        var bothHome = Path.Combine(root, "opencode-both-home");
        using var both = new Fixture(Path.Combine(bothHome, ".local", "share", "opencode", "opencode.db"));
        both.Run($"CREATE TABLE session {SessionColumns}");
        both.Run($"CREATE TABLE session_v2 {SessionColumns}");
        foreach (var table in v1Tables) both.Run(table);
        both.Run(V2Table);
        Session(both, "session", "ses_both", "/tmp/BothProject", "PRIVATE old title", -100);
        Session(both, "session_v2", "ses_both", "/tmp/BothProject", "Migrated title", -5);
        V1(both, "m1", "ses_both", -120, -120, V1User(-120));
        V1(both, "m2", "ses_both", -110, -100, V1Assistant("m1", -110, -100, "stop", 111));
        V2(both, "m1", "ses_both", "user", -120, -120, Prompt(-120));
        V2(both, "m2", "ses_both", "assistant", -110, -100, Step(-110, -100, finish: "stop", output: 111, content: [text]));
        V2(both, "m3", "ses_both", "user", -10, -10, Prompt(-10));
        V2(both, "m4", "ses_both", "assistant", -8, -5, Step(-8, -5, finish: "stop", output: 222, content: [text]));
        // A session an older (v1) build kept writing after the migration copied it.
        Session(both, "session", "ses_v1newer", "/tmp/NewerV1", null, -7);
        V2(both, "n1", "ses_v1newer", "user", -200, -200, Prompt(-200));
        V2(both, "n2", "ses_v1newer", "assistant", -190, -180, Step(-190, -180, finish: "stop", output: 50, content: [text]));
        V1(both, "n1", "ses_v1newer", -200, -200, V1User(-200));
        V1(both, "n2", "ses_v1newer", -190, -180, V1Assistant("n1", -190, -180, "stop", 50));
        V1(both, "n3", "ses_v1newer", -8, -8, V1User(-8));
        V1(both, "n4", "ses_v1newer", -7, -7, V1Assistant("n3", -7));
        both.Run("INSERT INTO part VALUES ('np', 'n4', 'ses_v1newer', ?, ?, ?)", Ms(-6), Ms(-6),
            Json(new { type = "tool", tool = "bash", state = new { status = "running", input = new { command = "PRIVATE" }, time = new { start = Ms(-6) } } }));
        if (both.Failed)
        {
            check(false, "OpenCode both-stores fixture: SQL failed");
            return;
        }
        var bothRows = new TokenTracker(bothHome, () => now, discoveryIntervalSeconds: 0, environment: _ => null).Sample()
            .Where(r => r.Source == TokenSource.OpenCode).ToList();
        check(bothRows.Count(r => r.SessionID == "ses_both") == 1
              && Row(bothRows, "ses_both") is { LastOutputTokens: 222, ActivityState: TokenActivityState.Complete, Title: "Migrated title" } merged
              && merged.RecentOutputs.Sum(e => e.Tokens) == 333 && !Leaks(bothRows),
              "OpenCode: a session in both stores was counted twice or not read from the store with the newest message, or its v2 title was lost");
        check(bothRows.Count == 2 && Row(bothRows, "ses_v1newer") is { ActivityState: TokenActivityState.Tool, ToolName: "bash", CurrentTurnOutputTokens: 0 } newer
              && newer.CurrentTurnStartedAt == now.AddSeconds(-8),
              "OpenCode: a session whose v1 messages are newer than its v2 copy was not read from v1");

        // Kilo Code's store (OpenCode's v1 schema) and MiMo Code's (no session agent or model, a title source, subagent threads
        // in the session's own message table).
        var appsHome = Path.Combine(root, "opencode-apps-home");
        var data = Path.Combine(appsHome, ".local", "share");
        using var kilo = new Fixture(Path.Combine(data, "kilo", "kilo.db"));
        kilo.Run($"CREATE TABLE session {SessionColumns}");
        foreach (var table in v1Tables) kilo.Run(table);
        Session(kilo, "session", "ses_kilo", "/tmp/KiloProject", "Kilo task", -9);
        V1(kilo, "k1", "ses_kilo", -10, -10, V1User(-10));
        V1(kilo, "k2", "ses_kilo", -9, -9, V1Assistant("k1", -9));
        kilo.Run("INSERT INTO part VALUES ('kp', 'k2', 'ses_kilo', ?, ?, ?)", Ms(-8), Ms(-8),
            Json(new { type = "tool", tool = "grep", state = new { status = "running", input = new { pattern = "PRIVATE" }, time = new { start = Ms(-8) } } }));
        using var mimo = new Fixture(Path.Combine(data, "mimocode", "mimocode.db"));
        mimo.Run("CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL, title_source TEXT NOT NULL DEFAULT 'user', version TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER)");
        mimo.Run("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, agent_id TEXT NOT NULL DEFAULT 'main', time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)");
        mimo.Run(v1Tables[1]);
        mimo.Run("INSERT INTO session VALUES ('ses_mimo', 'prj', NULL, 'mimo', '/tmp/MimoProject', 'PRIVATE first prompt', 'fallback', '0.1.14', ?, ?, NULL)", Ms(-30), Ms(-4));
        mimo.Run("INSERT INTO session VALUES ('ses_mimo_named', 'prj', NULL, 'named', '/tmp/MimoProject', 'Generated title', 'generated', '0.1.14', ?, ?, NULL)", Ms(-40), Ms(-30));
        mimo.Run("INSERT INTO message VALUES ('x1', 'ses_mimo', 'main', ?, ?, ?)", Ms(-20), Ms(-20), V1User(-20));
        mimo.Run("INSERT INTO message VALUES ('x2', 'ses_mimo', 'main', ?, ?, ?)", Ms(-18), Ms(-15), V1Assistant("x1", -18, -15, "stop", 70));
        mimo.Run("INSERT INTO message VALUES ('x3', 'ses_mimo', 'explore-1', ?, ?, ?)", Ms(-5), Ms(-4), V1Assistant("x1", -5));
        mimo.Run("INSERT INTO message VALUES ('y1', 'ses_mimo_named', 'main', ?, ?, ?)", Ms(-30), Ms(-30), V1User(-30));
        if (kilo.Failed || mimo.Failed)
        {
            check(false, "OpenCode apps fixture: SQL failed");
            return;
        }
        var appsTracker = new TokenTracker(appsHome, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
        var appRows = appsTracker.Sample().Where(r => r.Source == TokenSource.OpenCode).ToList();
        check(Row(appRows, "ses_kilo") is { ClientName: "Kilo Code", ActivityState: TokenActivityState.Tool, ToolName: "grep", ToolCategory: ToolCategory.File,
                  Title: "Kilo task", Project: "KiloProject", Model: "fixture-model" } kiloRow
              && kiloRow.Id.EndsWith("kilo.db#ses_kilo", StringComparison.Ordinal),
              "Kilo Code: its kilo.db was not read as an OpenCode store labelled Kilo Code");
        check(Row(appRows, "ses_mimo") is { ClientName: "MiMo Code", ActivityState: TokenActivityState.Complete, LastOutputTokens: 70, Model: "fixture-model", Title: null }
              && Row(appRows, "ses_mimo_named") is { Title: "Generated title", ClientName: "MiMo Code", ActivityState: TokenActivityState.Working }
              && appRows.Count == 3 && !Leaks(appRows),
              "MiMo Code: a subagent thread changed the main turn, a fallback title showed, or the rows were not labelled MiMo Code");

        var mimoHome = Path.GetFullPath(Path.Combine(root, "mimo-home"));
        var kiloFile = Path.GetFullPath(Path.Combine(root, "kilo-x", "k.db"));
        var opencodeRoots = TokenProvider.All.First(provider => provider.Source == TokenSource.OpenCode)
            .Roots(appsHome, key => key switch { "MIMOCODE_HOME" => mimoHome, "KILO_DB" => kiloFile, _ => null });
        var (opencodeApp, kiloApp, mimoApp) = (OpenCodeApp.All[0], OpenCodeApp.All[1], OpenCodeApp.All[2]);
        var xdg = Path.GetFullPath(Path.Combine(root, "xdg"));
        check(appsTracker.IsLog(Path.Combine(data, "kilo", "kilo-beta.db")) && appsTracker.IsLog(Path.Combine(data, "mimocode", "mimocode-dev.db"))
              && OpenCodeApp.Of(Path.Combine(data, "kilo", "opencode-dev.db"))?.Client == "Kilo Code"
              && OpenCodeApp.Of(Path.Combine(data, "opencode", "opencode-dev.db")) is { Client: null }
              && !appsTracker.IsLog(Path.Combine(data, "kilo", "kilo.json"))
              && kiloApp.DatabasePath(appsHome, key => key == "KILO_DB" ? "custom.db" : null) == Path.GetFullPath(Path.Combine(data, "kilo", "custom.db"))
              && kiloApp.DatabasePath(appsHome, key => key == "KILO_DB" ? ":memory:" : null) is null
              && mimoApp.DatabasePath(appsHome, key => key switch { "MIMOCODE_HOME" => mimoHome, "MIMOCODE_DB" => "x.db", _ => null })
                  == Path.Combine(mimoHome, "data", "x.db")
              && opencodeApp.DataFolder(appsHome, key => key == "XDG_DATA_HOME" ? xdg : null) == Path.Combine(xdg, "opencode")
              && opencodeRoots.SequenceEqual([Path.Combine(data, "opencode"), Path.GetDirectoryName(kiloFile)!, Path.Combine(data, "kilo"), Path.Combine(mimoHome, "data")]),
              "OpenCode apps: Kilo Code or MiMo Code database files, their variables or data folders are not resolved like the apps");
    }
}
