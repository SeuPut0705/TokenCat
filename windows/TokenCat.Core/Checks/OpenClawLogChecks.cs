using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenCat;

/// OpenClawLogChecks.swift: OpenClaw fixtures for both storage generations (synthetic metadata, no transcript text) — a running
/// tool turn, a finished turn with its output, transcript-only rows, `endTurn: false`, waiting for the person, model, project,
/// titles, a subagent under its parent, compressed rows and the entry total that settles them. Run from `TrackerChecks.Run`;
/// descriptions verbatim. Shapes follow openclaw/openclaw: `src/state/openclaw-agent-schema.sql` (tables, a subset of their
/// columns), `src/config/sessions/transcript-payload.ts` and `session-model-context-projection.ts` (`navigation_json` of a
/// compressed row), `packages/llm-core/src/types.ts` (messages), `src/config/sessions/types.ts` (session entry fields).
static class OpenClawLogChecks
{
    static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-04T08:00:00Z", CultureInfo.InvariantCulture);
    static string Iso(double seconds) => Start.AddSeconds(seconds).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    static long Ms(double seconds) => Start.AddSeconds(seconds).ToUnixTimeMilliseconds();

    static JsonObject Header(string id, string cwd) =>
        new() { ["type"] = "session", ["version"] = 3, ["id"] = id, ["timestamp"] = Iso(0), ["cwd"] = cwd };

    static JsonObject User(string id, double seconds) =>
        new()
        {
            ["type"] = "message", ["id"] = id, ["timestamp"] = Iso(seconds),
            ["message"] = new JsonObject { ["role"] = "user", ["content"] = "PRIVATE_PROMPT", ["timestamp"] = Ms(seconds) },
        };

    static JsonObject Assistant(string id, double seconds, int output, string stop, (string Id, string Name)? tool = null, JsonObject? extra = null)
    {
        var content = new JsonArray(new JsonObject { ["type"] = "thinking", ["thinking"] = "PRIVATE_THOUGHT" },
            new JsonObject { ["type"] = "text", ["text"] = "PRIVATE_REPLY" });
        if (tool is { } call)
            content.Add(new JsonObject { ["type"] = "toolCall", ["id"] = call.Id, ["name"] = call.Name, ["arguments"] = new JsonObject { ["command"] = "PRIVATE_CMD" } });
        var message = new JsonObject
        {
            ["role"] = "assistant", ["content"] = content, ["api"] = "anthropic-messages", ["provider"] = "anthropic", ["model"] = "claude-fixture",
            ["stopReason"] = stop, ["timestamp"] = Ms(seconds - 2),
            ["usage"] = new JsonObject { ["input"] = 10, ["output"] = output, ["cacheRead"] = 5_000, ["cacheWrite"] = 990, ["totalTokens"] = 6_000 + output },
        };
        foreach (var (key, value) in extra ?? new JsonObject()) message[key] = value?.DeepClone();
        return new JsonObject { ["type"] = "message", ["id"] = id, ["timestamp"] = Iso(seconds), ["message"] = message };
    }

    static JsonObject ToolResult(string id, double seconds, string call) =>
        new()
        {
            ["type"] = "message", ["id"] = id, ["timestamp"] = Iso(seconds),
            ["message"] = new JsonObject
            {
                ["role"] = "toolResult", ["toolCallId"] = call, ["toolName"] = "exec",
                ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = "PRIVATE_OUT" }), ["isError"] = false, ["timestamp"] = Ms(seconds),
            },
        };

    /// What OpenClaw writes as transcript bookkeeping after a channel delivery: no model output.
    static JsonObject Mirror(string id, double seconds) =>
        new()
        {
            ["type"] = "message", ["id"] = id, ["timestamp"] = Iso(seconds),
            ["message"] = new JsonObject
            {
                ["role"] = "assistant", ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = "PRIVATE_DELIVERED" }),
                ["api"] = "openclaw-transcript", ["provider"] = "openclaw", ["model"] = "delivery-mirror", ["stopReason"] = "stop", ["timestamp"] = Ms(seconds),
                ["usage"] = new JsonObject { ["input"] = 0, ["output"] = 0, ["cacheRead"] = 0, ["cacheWrite"] = 0, ["totalTokens"] = 0 },
            },
        };

    static void Append(string path, params JsonNode[] records)
    {
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        stream.Write(Encoding.UTF8.GetBytes(string.Concat(records.Select(record => record.ToJsonString() + "\n"))));
    }

    static string Encoded(IEnumerable<TokenReading> readings) => JsonSerializer.Serialize(readings);

    public static void Run(string root, Action<bool, string> check)
    {
        // JSONL generation: sessions/<sessionId>.jsonl with the sessions.json index.
        try
        {
            var home = Path.Combine(root, "openclaw-legacy-home");
            var sessions = Path.Combine(home, ".openclaw", "agents", "main", "sessions");
            Directory.CreateDirectory(sessions);
            File.WriteAllText(Path.Combine(sessions, "sessions.json"), new JsonObject
            {
                ["agent:main:main"] = new JsonObject
                {
                    ["sessionId"] = "oc-main", ["updatedAt"] = Ms(1), ["label"] = "Renamed OpenClaw chat", ["totalTokens"] = 1,
                    ["totalTokensFresh"] = true, ["contextTokens"] = 100_000, ["contextTokensSource"] = "runtime-configured",
                },
                ["agent:main:subagent:7f3c"] = new JsonObject
                {
                    ["sessionId"] = "oc-sub", ["updatedAt"] = Ms(20), ["spawnedBy"] = "agent:main:main", ["label"] = "researcher",
                },
                ["agent:main:whatsapp:direct:PRIVATE_PEER"] = new JsonObject
                {
                    ["sessionId"] = "oc-ask", ["updatedAt"] = Ms(1), ["origin"] = new JsonObject { ["label"] = "PRIVATE_CONTACT" },
                },
            }.ToJsonString());
            var main = Path.Combine(sessions, "oc-main.jsonl");
            Append(main, Header("oc-main", "/tmp/Fixture/ClawProject"),
                new JsonObject { ["type"] = "model_change", ["id"] = "m1", ["timestamp"] = Iso(0), ["provider"] = "anthropic", ["modelId"] = "claude-fixture" },
                User("u1", 10), Assistant("a1", 20, 40, "toolUse", ("call-1", "exec")));
            Append(Path.Combine(sessions, "oc-sub.jsonl"), Header("oc-sub", "/tmp/Fixture/ClawProject"), User("s1", 15), Assistant("s2", 18, 12, "stop"));
            Append(Path.Combine(sessions, "oc-ask.jsonl"), Header("oc-ask", "/tmp/Fixture/AskProject"), User("q1", 30),
                Assistant("q2", 35, 3, "toolUse", ("call-q", "ask_user")));
            var now = Start.AddSeconds(60);
            var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            var rows = tracker.Sample();
            var row = rows.FirstOrDefault(r => r.SessionID == "oc-main");
            check(row is { Source: var source, Active: true, ActivityState: TokenActivityState.Tool, ToolName: "exec", ToolCategory: ToolCategory.Command,
                      CurrentTurnOutputTokens: 40, Model: "claude-fixture", Project: "ClawProject", ProjectPath: "/tmp/Fixture/ClawProject",
                      Title: "Renamed OpenClaw chat", Context: { UsedTokens: 6_000, WindowTokens: 100_000 }, IsSubagent: false, SpeedMeasurement: null }
                  && source == TokenSource.OpenClaw && row.CurrentTurnStartedAt == Start.AddSeconds(10)
                  && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([40]),
                  "OpenClaw JSONL: a reply calling a tool was not a running tool turn with its output, model, context, project and renamed title");
            var sub = rows.FirstOrDefault(r => r.SessionID == "oc-sub");
            check(sub is { IsSubagent: true, ParentSessionID: "oc-main", AgentID: "oc-sub", AgentRole: "researcher",
                      ActivityState: TokenActivityState.Complete, LastOutputTokens: 12, Title: null },
                  "OpenClaw JSONL: a spawned session was not a subagent under its parent, named by its label, with its output");
            var ask = rows.FirstOrDefault(r => r.SessionID == "oc-ask");
            check(ask is { ActivityState: TokenActivityState.Input, Active: true, ToolCategory: ToolCategory.Question, Title: null },
                  "OpenClaw JSONL: ask_user did not wait for the person, or a channel session without a title got one");

            Append(main, ToolResult("t1", 30, "call-1"), Assistant("a2", 45, 60, "stop"), Mirror("d1", 46));
            now = Start.AddSeconds(50);
            rows = tracker.Sample();
            row = rows.FirstOrDefault(r => r.SessionID == "oc-main");
            check(row is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 100, CurrentTurnOutputTokens: null, ToolName: null }
                  && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([40, 60]) && row.MeasurementAt == Start.AddSeconds(45)
                  && rows.Count == 3 && !Encoded(rows).Contains("PRIVATE", StringComparison.Ordinal),
                  "OpenClaw JSONL: a stop reply did not complete the turn with its whole output, a delivery mirror reopened it, or text leaked");
            var tailOnly = new TokenTracker(home, () => now, initialTailBytes: 900, environment: _ => null).Sample()
                .FirstOrDefault(r => r.Id.EndsWith("oc-main.jsonl", StringComparison.Ordinal));
            check(tailOnly is { SessionID: "oc-main", Project: "ClawProject", ActivityState: TokenActivityState.Complete },
                  "OpenClaw JSONL: the session header was lost when the first read started mid-file");
            var agents = Path.Combine(home, ".openclaw", "agents", "main");
            check(tracker.IsLog(main) && tracker.IsLog(Path.Combine(agents, "agent", "openclaw-agent.sqlite"))
                  && tracker.WakesSampling(Path.Combine(agents, "agent", "openclaw-agent.sqlite-wal"))
                  && !tracker.IsLog(main + ".reset.2026-10-04T08-00-00.000Z")
                  && !tracker.IsLog(Path.Combine(agents, "sessions", "sessions.json"))
                  && !tracker.IsLog(Path.Combine(agents, "agent", "incognito-openclaw-agent.sqlite"))
                  && !tracker.IsLog(Path.Combine(agents, "agent", "codex-home", "sessions", "2026", "10", "04", "rollout-x.jsonl"))
                  && !tracker.IsLog(Path.Combine(agents, "session-sqlite-import-archive", "k.oc-main.jsonl")),
                  "OpenClaw: transcript, database or archive path matching is wrong");
            var state = Path.Combine(root, "claw-state");
            var environment = new Dictionary<string, string> { ["OPENCLAW_STATE_DIR"] = state, ["OPENCLAW_PROFILE"] = "work" };
            var roots = TokenProvider.All.FirstOrDefault(p => p.Source == TokenSource.OpenClaw)?.Roots(home, key => environment.GetValueOrDefault(key)) ?? [];
            check(roots.SequenceEqual([Path.Combine(state, "agents"), Path.Combine(home, ".openclaw-work", "agents"), Path.Combine(home, ".openclaw", "agents"),
                      Path.Combine(home, ".openclaw", "agents"), Path.Combine(home, ".clawdbot", "agents"), Path.Combine(home, ".moltbot", "agents")]),
                  "OpenClaw: OPENCLAW_STATE_DIR, a named profile or the legacy state folders are not roots");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            check(false, $"OpenClaw JSONL fixture error: {error.Message}");
        }

        // SQLite generation: agent/openclaw-agent.sqlite.
        var dbHome = Path.Combine(root, "openclaw-db-home");
        var folder = Path.Combine(dbHome, ".openclaw", "agents", "main", "agent");
        Directory.CreateDirectory(folder);
        using var database = OpenCodeDatabase.Open(Path.Combine(folder, "openclaw-agent.sqlite"), create: true);
        if (database is null)
        {
            check(false, "OpenClaw fixture: database not created");
            return;
        }
        var failed = false;
        void Sql(string sql, params object?[] values) => failed |= !database.Query(sql, values, _ => { });
        Sql("""
            CREATE TABLE session_nodes (session_key TEXT NOT NULL PRIMARY KEY, current_session_id TEXT NOT NULL, entry_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL, label TEXT, display_name TEXT)
            """);
        Sql("""
            CREATE TABLE session_windows (session_id TEXT NOT NULL PRIMARY KEY, session_key TEXT NOT NULL, previous_session_id TEXT,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, transcript_updated_at INTEGER DEFAULT NULL, model_provider TEXT,
                model TEXT, agent_harness_id TEXT)
            """);
        Sql("""
            CREATE TABLE transcript_events (session_id TEXT NOT NULL, seq INTEGER NOT NULL, event_json TEXT, created_at INTEGER NOT NULL,
                event_zstd BLOB, event_utf8_bytes INTEGER, navigation_json TEXT, PRIMARY KEY (session_id, seq))
            """);
        var seqs = new Dictionary<string, long>(StringComparer.Ordinal);
        void Session(string id, string key, JsonObject entry, double updated)
        {
            Sql("INSERT OR REPLACE INTO session_nodes VALUES (?, ?, ?, ?, NULL, NULL)", key, id, entry.ToJsonString(), Ms(updated));
            Sql("INSERT OR REPLACE INTO session_windows VALUES (?, ?, NULL, ?, ?, ?, 'anthropic', 'window-model', 'pi')", id, key, Ms(0), Ms(updated), Ms(updated));
        }
        void Touch(string id, double seconds) =>
            Sql("UPDATE session_windows SET updated_at = ?, transcript_updated_at = ? WHERE session_id = ?", Ms(seconds), Ms(seconds), id);
        long Next(string id) => seqs[id] = seqs.GetValueOrDefault(id, -1) + 1;
        void Event(string id, JsonNode record, double seconds)
        {
            Sql("INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES (?, ?, ?, ?)", id, Next(id), record.ToJsonString(), Ms(seconds));
            Touch(id, seconds);
        }
        // A row stored as a zstd frame: the body is opaque here, and only the navigation facts are plain.
        void Compressed(string id, double seconds, JsonObject message, string? idempotencyKey = null)
        {
            var seq = Next(id);
            JsonObject Entry() => new() { ["type"] = "message", ["id"] = $"z{seq}", ["parentId"] = $"p{seq}", ["timestamp"] = Iso(seconds) };
            var navigationMessage = new JsonObject { ["role"] = message["role"]?.DeepClone() ?? JsonValue.Create("assistant") };
            if (idempotencyKey is not null) navigationMessage["idempotencyKey"] = idempotencyKey;
            var model = Entry();
            var body = (JsonObject)message.DeepClone();
            body["command"] = "";
            body["output"] = "";
            body["providerReplay"] = new JsonObject { ["type"] = null };
            body["details"] = new JsonObject { ["synthetic"] = false };
            model["message"] = body;
            var navigationEntry = Entry();
            navigationEntry["message"] = navigationMessage;
            var navigation = new JsonObject
            {
                ["version"] = 1, ["report"] = new JsonObject { ["kind"] = "canonical", ["hasParentId"] = true, ["entry"] = Entry() },
                ["navigation"] = navigationEntry, ["reset"] = Entry(), ["model"] = model,
                ["modelBytes"] = 2_048, ["modelWithoutCheckpointBytes"] = 2_048, ["withoutCustomDataBytes"] = 2_048,
            };
            Sql("INSERT INTO transcript_events VALUES (?, ?, NULL, ?, CAST(? AS BLOB), 4096, ?)", id, seq, Ms(seconds), "PRIVATE zstd frame", navigation.ToJsonString());
            Touch(id, seconds);
        }
        // A running turn: a readable reply ran exec, then compressed rows finished it and called read.
        Session("ses-work", "agent:main:main", new JsonObject
        {
            ["sessionId"] = "ses-work", ["updatedAt"] = Ms(5), ["displayName"] = "Generated DB title", ["outputTokens"] = 999, ["totalTokens"] = 4_000,
            ["totalTokensFresh"] = true, ["contextTokens"] = 200_000, ["contextTokensSource"] = "runtime", ["model"] = "entry-model",
        }, 5);
        Event("ses-work", Header("ses-work", "/tmp/Fixture/ClawDb"), 0);
        Event("ses-work", new JsonObject
        {
            ["type"] = "model_change", ["id"] = "m1", ["parentId"] = null, ["timestamp"] = Iso(0), ["provider"] = "anthropic", ["modelId"] = "claude-fixture",
        }, 0);
        Event("ses-work", User("u1", 10), 10);
        Event("ses-work", Assistant("a1", 20, 30, "toolUse", ("call-1", "exec")), 20);
        Compressed("ses-work", 30, new JsonObject
        {
            ["role"] = "toolResult", ["toolCallId"] = "call-1", ["toolName"] = "exec", ["isError"] = false, ["timestamp"] = Ms(30), ["content"] = new JsonArray(),
        });
        Compressed("ses-work", 40, new JsonObject
        {
            ["role"] = "assistant", ["provider"] = "anthropic", ["model"] = "claude-fixture", ["timestamp"] = Ms(32), ["stopReason"] = "toolUse",
            ["content"] = new JsonArray(new JsonObject { ["type"] = "toolCall", ["id"] = "call-2", ["name"] = "read" }),
        });
        // A subagent: its parent is the spawning key's current session.
        Session("ses-sub", "agent:main:subagent:7f3c", new JsonObject
        {
            ["sessionId"] = "ses-sub", ["updatedAt"] = Ms(26), ["label"] = "fixer", ["spawnedBy"] = "agent:main:main", ["outputTokens"] = 9,
        }, 26);
        Event("ses-sub", Header("ses-sub", "/tmp/Fixture/ClawDb"), 0);
        Event("ses-sub", User("s1", 15), 15);
        Event("ses-sub", Assistant("s2", 25, 9, "stop"), 25);
        // A question for the person on a channel session (its key names a peer, never shown).
        Session("ses-ask", "agent:main:telegram:direct:PRIVATE_PEER", new JsonObject { ["sessionId"] = "ses-ask", ["updatedAt"] = Ms(1) }, 35);
        Event("ses-ask", Header("ses-ask", "/tmp/Fixture/AskProject"), 0);
        Event("ses-ask", User("q1", 30), 30);
        Event("ses-ask", Assistant("q2", 35, 4, "toolUse", ("call-q", "ask_user")), 35);
        // A finished cron turn: `endTurn: false` asked for another inference; a delivery mirror followed the answer.
        Session("ses-done", "agent:main:cron:job-1", new JsonObject { ["sessionId"] = "ses-done", ["updatedAt"] = Ms(7) }, 7);
        Event("ses-done", Header("ses-done", "/tmp/Fixture/CronProject"), 0);
        Event("ses-done", User("c1", 1), 1);
        Event("ses-done", Assistant("c2", 3, 5, "stop", extra: new JsonObject { ["endTurn"] = false }), 3);
        Event("ses-done", Assistant("c3", 5, 45, "stop"), 5);
        Event("ses-done", Mirror("c4", 6), 6);
        // A Codex app-server turn: the mirrored reply carries the last response's usage; the entry holds the run's total.
        Session("ses-codex", "agent:main:codex", new JsonObject { ["sessionId"] = "ses-codex", ["updatedAt"] = Ms(9), ["outputTokens"] = 300 }, 9);
        Event("ses-codex", Header("ses-codex", "/tmp/Fixture/CodexProject"), 0);
        Event("ses-codex", User("x1", 2), 2);
        Event("ses-codex", Assistant("x2", 8, 7, "stop", extra: new JsonObject { ["idempotencyKey"] = "codex-app-server:t1:u1:assistant" }), 8);
        if (failed)
        {
            check(false, "OpenClaw fixture: SQL failed");
            return;
        }

        var dbNow = Start.AddSeconds(60);
        var dbTracker = new TokenTracker(dbHome, () => dbNow, discoveryIntervalSeconds: 0, environment: _ => null);
        var dbRows = dbTracker.Sample().Where(r => r.Source == TokenSource.OpenClaw).ToList();
        TokenReading? Row(string id) => dbRows.FirstOrDefault(r => r.SessionID == id);
        var work = Row("ses-work");
        check(work is { Active: true, ActivityState: TokenActivityState.Tool, ToolName: "read", ToolCategory: ToolCategory.File, CurrentTurnOutputTokens: null,
                  Model: "claude-fixture", Project: "ClawDb", ProjectPath: "/tmp/Fixture/ClawDb", Title: "Generated DB title",
                  Context: { UsedTokens: 6_000, WindowTokens: 200_000 }, LastOutputTokens: null }
              && work.CurrentTurnStartedAt == Start.AddSeconds(10) && work.RecentOutputs.Select(e => e.Tokens).SequenceEqual([30])
              && work.Id.EndsWith("openclaw-agent.sqlite#ses-work", StringComparison.Ordinal),
              "OpenClaw SQLite: compressed rows did not keep the tool turn, or its output was counted as whole without readable usage");
        var dbSub = Row("ses-sub");
        check(dbSub is { IsSubagent: true, ParentSessionID: "ses-work", AgentID: "ses-sub", AgentRole: "fixer",
                  ActivityState: TokenActivityState.Complete, LastOutputTokens: 9, Title: null },
              "OpenClaw SQLite: a spawned session was not grouped under the spawning key's current session");
        var dbAsk = Row("ses-ask");
        check(dbAsk is { ActivityState: TokenActivityState.Input, Active: true, ToolName: "ask_user", Title: null, Project: "AskProject", IsSubagent: false },
              "OpenClaw SQLite: ask_user did not wait for the person");
        var done = Row("ses-done");
        check(done is { ActivityState: TokenActivityState.Complete, Active: false, LastOutputTokens: 50, Model: "claude-fixture" }
              && done.RecentOutputs.Select(e => e.Tokens).SequenceEqual([5, 45]) && done.MeasurementAt == Start.AddSeconds(5),
              "OpenClaw SQLite: endTurn false ended the turn, or a delivery mirror counted as a reply");
        var codex = Row("ses-codex");
        check(codex is { LastOutputTokens: 300, ActivityState: TokenActivityState.Complete } && codex.RecentOutputs.Select(e => e.Tokens).SequenceEqual([7, 293]),
              "OpenClaw SQLite: a Codex app-server mirror was not settled by the session entry's output total");
        check(dbRows.Count == 5 && !Encoded(dbRows).Contains("PRIVATE", StringComparison.Ordinal),
              "OpenClaw SQLite: a session is missing, or a session key, body or text leaked into a reading");

        // The turn ends in compressed rows; its output is unknown until the entry written after the run settles it.
        Compressed("ses-work", 50, new JsonObject
        {
            ["role"] = "toolResult", ["toolCallId"] = "call-2", ["toolName"] = "read", ["isError"] = false, ["timestamp"] = Ms(50), ["content"] = new JsonArray(),
        });
        Compressed("ses-work", 70, new JsonObject
        {
            ["role"] = "assistant", ["provider"] = "anthropic", ["model"] = "claude-fixture", ["timestamp"] = Ms(62), ["stopReason"] = "stop", ["content"] = new JsonArray(),
        });
        dbNow = Start.AddSeconds(80);
        dbRows = [.. dbTracker.Sample().Where(r => r.Source == TokenSource.OpenClaw)];
        work = Row("ses-work");
        var unsettled = work is { ActivityState: TokenActivityState.Complete, Active: false, LastOutputTokens: null, CurrentTurnOutputTokens: null, ToolName: null };
        Sql("UPDATE session_nodes SET entry_json = ?, updated_at = ? WHERE session_key = 'agent:main:main'", new JsonObject
        {
            ["sessionId"] = "ses-work", ["updatedAt"] = Ms(71), ["displayName"] = "Generated DB title", ["outputTokens"] = 130, ["totalTokens"] = 7_000,
            ["totalTokensFresh"] = true, ["contextTokens"] = 200_000, ["contextTokensSource"] = "runtime",
        }.ToJsonString(), Ms(71));
        dbRows = [.. dbTracker.Sample().Where(r => r.Source == TokenSource.OpenClaw)];
        work = Row("ses-work");
        check(!failed && unsettled && work is { LastOutputTokens: 130, Context: { UsedTokens: 7_000, WindowTokens: 200_000 } }
              && work.RecentOutputs.Select(e => e.Tokens).SequenceEqual([30, 100]) && work.RecentOutputs[^1].At == Start.AddSeconds(71)
              && work.MeasurementAt == Start.AddSeconds(70),
              "OpenClaw SQLite: a turn ending in compressed rows was not settled by the entry's output total, or its context was stale");
    }
}
