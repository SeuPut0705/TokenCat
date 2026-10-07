using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenCat;

/// KimiChecks.swift: Kimi Code, Kimi Work and kimi-cli fixture checks, run inside `TrackerChecks.Run`, descriptions verbatim.
/// Synthetic metadata only, temp homes; record shapes follow MoonshotAI/kimi-code and the archived MoonshotAI/kimi-cli.
public static class KimiChecks
{
    static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-04T12:00:00Z", CultureInfo.InvariantCulture);
    static long Ms(double seconds) => Start.AddSeconds(seconds).ToUnixTimeMilliseconds();
    static JsonNode N(string json) => JsonNode.Parse(json)!;

    /// Kimi Code serializes `{"type", …payload, "time"}` in that order.
    static string Wire(string type, double at, string payload = "{}")
    {
        var body = N(payload).ToJsonString();
        body = body.Length > 2 ? body[1..^1] + "," : "";
        return $"{{\"type\":\"{type}\",{body}\"time\":{Ms(at)}}}";
    }

    static string Loop(double at, string @event, string agent = "main") => Wire("context.append_loop_event", at,
        new JsonObject { ["agentId"] = agent, ["event"] = N(@event) }.ToJsonString());

    /// kimi-cli writes `{"timestamp", "message": {"type", "payload"}}`.
    static string Legacy(string type, double at, string payload = "{}") =>
        $"{{\"timestamp\":{(Start.AddSeconds(at).ToUnixTimeMilliseconds() / 1000.0).ToString("0.0##", CultureInfo.InvariantCulture)},\"message\":{{\"type\":\"{type}\",\"payload\":{N(payload).ToJsonString()}}}}}";

    static void Write(string path, params string[] lines)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes(string.Concat(lines.Select(line => line + "\n"))));
    }

    static void Append(string path, params string[] lines)
    {
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        stream.Write(Encoding.UTF8.GetBytes(string.Concat(lines.Select(line => line + "\n"))));
    }

    static string Encoded(IEnumerable<TokenReading> readings) => Encoding.UTF8.GetString(Json.Serialize(readings.ToList()));

    static string Usage(double at, int output, string scope = "turn", string agent = "main") => Wire("usage.record", at,
        $$$"""{"agentId":"{{{agent}}}","model":"kimi-code/k2","usageScope":"{{{scope}}}","usage":{"inputOther":1000,"output":{{{output}}},"inputCacheRead":500,"inputCacheCreation":0}}""");

    static string Request(double at, string model = "kimi-code/kimi-k2-turbo", string kind = "loop", string agent = "main") => Wire("llm.request", at,
        $$"""{"agentId":"{{agent}}","kind":"{{kind}}","provider":"kimi","model":"{{model}}","modelAlias":"kimi-code/k2","thinkingEffort":"high","toolSelect":false,"systemPromptHash":"h","systemPrompt":"PRIVATE_SYSTEM","toolsHash":"t","messageCount":3,"turnStep":"1.1","attempt":"1"}""");

    static string StepEnd(double at, int output, string reason = "tool_use", string agent = "main") => Loop(at,
        $$"""{"type":"step.end","uuid":"{{Guid.NewGuid()}}","turnId":"1","step":1,"finishReason":"{{reason}}","usage":{"inputOther":1000,"output":{{output}},"inputCacheRead":500,"inputCacheCreation":0},"llmFirstTokenLatencyMs":500,"llmStreamDurationMs":1500}""", agent);

    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), $"TokenCat-kimi-{Guid.NewGuid()}");
        try
        {
            RunCode(root, check);
            RunLegacy(root, check);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    static void RunCode(string root, Action<bool, string> check)
    {
        try
        {
            // Kimi Code: a main agent and one subagent in a session folder, with the session's state.json.
            var home = Path.Combine(root, "code");
            var session = Path.Combine(home, ".kimi-code", "sessions", "wd_kimiproject_0123456789ab", "session_kimi-main");
            var mainWire = Path.Combine(session, "agents", "main", "wire.jsonl");
            var childWire = Path.Combine(session, "agents", "agent-0", "wire.jsonl");
            Write(Path.Combine(session, "state.json"),
                $$"""{"id":"session_kimi-main","version":1,"cwd":"/tmp/KimiProject","title":"Kimi fixture title","titleKind":"generated","isCustomTitle":false,"lastPrompt":"PRIVATE_PROMPT","createdAt":{{Ms(0)}},"updatedAt":{{Ms(1)}},"archived":false,"custom":{},"agents":{"main":{"homedir":"/tmp/h/main","type":"main"},"agent-0":{"homedir":"/tmp/h/agent-0","type":"sub","parentAgentId":"main","labels":{"profileName":"explore"} } } }""");
            Write(mainWire,
                $"{{\"type\":\"metadata\",\"protocol_version\":\"1.5\",\"created_at\":{Ms(0)}}}",
                Wire("profile.bind", 0, """{"agentId":"main","profileName":"coder","thinkingEffort":"high","systemPrompt":"PRIVATE_SYSTEM","environmentDisclosure":{"cwd":"/tmp/KimiProject"},"disallowedTools":[]}"""),
                Wire("turn.prompt", 1, """{"agentId":"main","input":[{"type":"text","text":"PRIVATE_PROMPT"}],"origin":"user","promptId":"p1","turnId":1}"""),
                Wire("context.append_message", 1, """{"agentId":"main","message":{"role":"user","content":[{"type":"text","text":"PRIVATE_PROMPT"}],"toolCalls":[]}}"""),
                Request(2),
                Loop(2, """{"type":"step.begin","uuid":"s1","turnId":"1","step":1}"""),
                Loop(3, """{"type":"content.part","stepUuid":"s1","part":{"type":"think","think":"PRIVATE_THINKING"}}"""),
                Loop(4, """{"type":"tool.call","stepUuid":"s1","toolCallId":"call_1","name":"Bash","args":{"command":"PRIVATE_COMMAND"},"uuid":"u1","turnId":"1","step":1}"""),
                StepEnd(4, 40),
                Usage(4, 40));
            Write(childWire,
                $"{{\"type\":\"metadata\",\"protocol_version\":\"1.5\",\"created_at\":{Ms(5)}}}",
                Wire("turn.prompt", 5, """{"agentId":"agent-0","input":[{"type":"text","text":"PRIVATE_TASK"}],"origin":"task","turnId":1}"""),
                Request(6, model: "kimi-k2-sub", agent: "agent-0"),
                Usage(7, 12, agent: "agent-0"),
                Wire("turn.ended", 8, """{"agentId":"agent-0","turnId":1,"reason":"completed","durationMs":3000}"""));
            var now = Start.AddSeconds(5);
            var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            var rows = tracker.Sample();
            var row = rows.FirstOrDefault(r => !r.IsSubagent);
            check(row is { Source: TokenSource.Kimi, Active: true, ActivityState: TokenActivityState.Tool, ToolName: "Bash", ToolCategory: ToolCategory.Command,
                      CurrentTurnOutputTokens: 40, Model: "kimi-k2-turbo", Effort: "high", Project: "KimiProject", ProjectPath: "/tmp/KimiProject",
                      SessionID: "session_kimi-main", Title: "Kimi fixture title", Context.UsedTokens: 1_500, ClientName: null }
                  && row.CurrentTurnStartedAt == Start.AddSeconds(1),
                  "Kimi Code: an open turn running a tool read cold lost its tool, turn output, model, effort, context, project or generated title");
            check(row?.SpeedMeasurement is { OutputTokens: 40, RequestDurationMs: 2_000, TtftMs: 500, TokensPerSecond: 20, Model: "kimi-k2-turbo" },
                  "Kimi Code: a step's own first-token and streaming time was not reported as a measured request rate");
            var child = rows.FirstOrDefault(r => r.IsSubagent);
            check(child is { ParentSessionID: "session_kimi-main", SessionID: "session_kimi-main", AgentID: "agent-0", AgentRole: "explore",
                      ActivityState: TokenActivityState.Complete, Active: false, LastOutputTokens: 12, Model: "kimi-k2-sub", Title: null, Project: "KimiProject" },
                  "Kimi Code: a subagent was not grouped under its session, named by its profile, or finished with its own output and model");

            // The tool result arrives (sorted keys: a writer that does not put `type` first is still read), then an approval wait.
            Append(mainWire,
                $$"""{"agentId":"main","event":{"parentUuid":"u1","result":{"output":"PRIVATE_OUTPUT"},"toolCallId":"call_1","type":"tool.result"},"time":{{Ms(10)}},"type":"context.append_loop_event"}""",
                Loop(11, """{"type":"tool.call","stepUuid":"s2","toolCallId":"call_2","name":"Bash","args":{"command":"PRIVATE"}}"""),
                Wire("interaction.request", 11, """{"agentId":"main","id":"int_1","kind":"approval","toolCallId":"call_2","request":{"command":"PRIVATE_COMMAND"}}"""));
            now = Start.AddSeconds(7_200);
            row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { ActivityState: TokenActivityState.Input, Active: true, ToolName: "Bash", CurrentTurnOutputTokens: 40 },
                  "Kimi Code: a two-hour-old approval request was not live input");
            Append(mainWire,
                Wire("interaction.resolved", 7_201, """{"agentId":"main","id":"int_1","response":{"decision":"PRIVATE"}}"""),
                Loop(7_202, """{"type":"tool.result","parentUuid":"u2","toolCallId":"call_2","result":{"output":"PRIVATE_OUTPUT"}}"""),
                Request(7_203),
                StepEnd(7_205, 60, "end_turn"),
                Usage(7_205, 60),
                Wire("turn.ended", 7_206, """{"agentId":"main","turnId":1,"reason":"completed","durationMs":9000,"stopReason":"end_turn"}"""),
                Wire("prompt.completed", 7_206, """{"agentId":"main","promptId":"p1","finishedAt":"2026-10-04T14:00:06Z","reason":"completed"}"""));
            now = Start.AddSeconds(7_207);
            row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 100, LastTurnDurationSeconds: 9,
                      CurrentTurnOutputTokens: null, ToolName: null, SpeedMeasurement.OutputTokens: 60 }
                  && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([60]),
                  "Kimi Code: turn.ended did not finish the turn with its whole output and the client's own duration");

            // Compaction between turns neither opens a turn nor counts as turn output.
            Append(mainWire, Request(7_300, model: "compaction-model", kind: "compaction"), Usage(7_301, 900, scope: "session"));
            now = Start.AddSeconds(7_302);
            row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { ActivityState: TokenActivityState.Complete, Model: "kimi-k2-turbo", LastOutputTokens: 100 }
                  && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([60]),
                  "Kimi Code: a compaction request or session-scoped usage reopened the turn, changed the model or counted as output");
            Append(mainWire, Wire("turn.prompt", 7_400, """{"agentId":"main","input":[{"type":"text","text":"PRIVATE"}],"origin":"user","turnId":2}"""));
            now = Start.AddSeconds(7_401);
            row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { ActivityState: TokenActivityState.Working, Active: true, CurrentTurnOutputTokens: 0, LastOutputTokens: 100 }
                  && row.CurrentTurnStartedAt == Start.AddSeconds(7_400),
                  "Kimi Code: a new prompt did not start a counted turn at zero");
            Append(mainWire, Wire("turn.ended", 7_410, """{"agentId":"main","turnId":2,"reason":"cancelled","durationMs":10000}"""));
            now = Start.AddSeconds(7_411);
            rows = tracker.Sample();
            row = rows.FirstOrDefault(r => !r.IsSubagent);
            check(row is { ActivityState: TokenActivityState.Interrupted, Active: false, LastOutputTokens: 100 },
                  "Kimi Code: a cancelled turn did not end as interrupted");
            check(!Encoded(rows).Contains("PRIVATE", StringComparison.Ordinal), "Kimi Code: transcript text leaked into a reading");

            // Titles: only generated or user-set ones; never the prompt copy, never an imported kimi-cli fallback.
            static JsonElement E(string json) => JsonDocument.Parse(json).RootElement;
            check(KimiLog.Title(E("""{"title":"Fix login","titleKind":"custom"}""")) == "Fix login"
                  && KimiLog.Title(E("""{"title":"PRIVATE_PROMPT","titleKind":"replaceable"}""")) is null
                  && KimiLog.Title(E("""{"title":"PRIVATE_PROMPT","isCustomTitle":false}""")) is null
                  && KimiLog.Title(E("""{"title":"Renamed","isCustomTitle":true}""")) == "Renamed"
                  && KimiLog.Title(E("""{"title":"PRIVATE_PROMPT","titleKind":"generated","custom":{"imported_from_kimi_cli":true}}""")) is null
                  && KimiLog.ModelName("kimi-code/kimi-for-coding") == "kimi-for-coding" && KimiLog.ModelName("__kimi_env_model__") is null,
                  "Kimi Code: a prompt-copy or imported title was shown, a generated or renamed one was not, or a model id was misread");

            // KIMI_CODE_HOME moves the store; Kimi Work's embedded runtime is labelled as such.
            var custom = Path.Combine(home, "custom-kimi");
            var workSession = Path.Combine(home, "AppData", "Roaming", "kimi-desktop", "daimon-share", "daimon", "runtime", "kimi-code", "home",
                "sessions", "wd_work_0123456789ab", "conv-work");
            foreach (var (folder, cwd) in new[] { (Path.Combine(custom, "sessions", "wd_moved_0123456789ab", "session_moved"), "/tmp/KimiMoved"),
                                                  (workSession, "/tmp/KimiWork") })
            {
                Write(Path.Combine(folder, "state.json"), $$"""{"id":"{{Path.GetFileName(folder)}}","cwd":"{{cwd}}","title":"PRIVATE_PROMPT","titleKind":"replaceable"}""");
                Write(Path.Combine(folder, "agents", "main", "wire.jsonl"), Wire("turn.prompt", 7_405, """{"agentId":"main","input":[],"origin":"user"}"""));
            }
            var moved = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: key => key == "KIMI_CODE_HOME" ? custom : null).Sample();
            check(moved.Any(r => r is { SessionID: "session_moved", Project: "KimiMoved", Title: null })
                  && !moved.Any(r => r.SessionID == "session_kimi-main")
                  && moved.FirstOrDefault(r => r.SessionID == "conv-work")?.ClientName == "Kimi Work",
                  "Kimi Code: KIMI_CODE_HOME was not followed, or a Kimi Work session was not labelled Kimi Work");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            check(false, $"Kimi Code fixtures could not be written: {error.Message}");
        }
    }

    static void RunLegacy(string root, Action<bool, string> check)
    {
        try
        {
            // kimi-cli: `sessions/<md5(work dir)>/<session>/wire.jsonl`, a subagent beside it, kimi.json and config.toml.
            var home = Path.Combine(root, "cli");
            var share = Path.Combine(home, ".kimi");
            var group = Path.Combine(share, "sessions", KimiLog.WorkDirFolder("/tmp/KimiLegacy", "local"));
            var session = Path.Combine(group, "legacy-session");
            var mainWire = Path.Combine(session, "wire.jsonl");
            Write(Path.Combine(share, "kimi.json"),
                """{"work_dirs":[{"path":"/tmp/Elsewhere","kaos":"local"},{"path":"/tmp/KimiLegacy","kaos":"local","last_session_id":"legacy-session"}]}""");
            Write(Path.Combine(share, "config.toml"), "default_model = \"k2\" # fixture", "", "[models.\"k2\"]", "provider = \"kimi\"",
                "model = \"kimi-k2-0905-preview\"", "max_context_size = 262144", "", "[models.other]", "model = \"other-model\"");
            static string Status(double at, int output, string id) => Legacy("StatusUpdate", at,
                $$"""{"token_usage":{"input_other":100,"output":{{output}},"input_cache_read":0,"input_cache_creation":0},"message_id":"{{id}}","context_tokens":5000,"max_context_tokens":262144,"context_usage":0.02,"plan_mode":false}""");
            Write(mainWire,
                """{"type":"metadata","protocol_version":"1.3"}""",
                Legacy("TurnBegin", 1, """{"user_input":"PRIVATE_PROMPT"}"""),
                Legacy("StepBegin", 2, """{"n":1}"""),
                Legacy("ContentPart", 3, """{"type":"text","text":"PRIVATE_REPLY"}"""),
                Legacy("ToolCall", 4, """{"type":"function","id":"tc1","function":{"name":"Shell","arguments":"PRIVATE_ARGS"}}"""),
                Legacy("ToolCallPart", 4, """{"arguments_part":"PRIVATE"}"""),
                Status(4, 30, "m1"));
            var agent = Path.Combine(session, "subagents", "a1234567");
            Write(Path.Combine(agent, "meta.json"),
                """{"agent_id":"a1234567","subagent_type":"coder","status":"completed","description":"PRIVATE_DESCRIPTION","created_at":1.0,"updated_at":2.0,"launch_spec":{"agent_id":"a1234567","subagent_type":"coder","effective_model":"kimi-k2-sub","created_at":1.0}}""");
            Write(Path.Combine(agent, "wire.jsonl"), Legacy("TurnBegin", 5, """{"user_input":"PRIVATE_TASK"}"""), Status(6, 7, "s1"), Legacy("TurnEnd", 7));
            // A session Kimi Code's migration already copied: written before the marker, so the Kimi Code copy is the one shown.
            var migrated = Path.Combine(group, "migrated-session", "wire.jsonl");
            Write(migrated, Legacy("TurnBegin", -90_000), Legacy("TurnEnd", -89_000));
            File.SetLastWriteTimeUtc(migrated, DateTime.UtcNow.AddDays(-1));
            var marker = Path.Combine(share, ".migrated-to-kimi-code");
            Write(marker);
            File.SetLastWriteTimeUtc(marker, DateTime.UtcNow.AddHours(-1));

            var now = Start.AddSeconds(5);
            var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            var rows = tracker.Sample();
            var row = rows.FirstOrDefault(r => !r.IsSubagent);
            check(row is { Source: TokenSource.Kimi, ClientName: "Kimi CLI", ActivityState: TokenActivityState.Tool, ToolName: "Shell", Active: true,
                      CurrentTurnOutputTokens: 30, Model: "kimi-k2-0905-preview", Project: "KimiLegacy", SessionID: "legacy-session",
                      Context: { UsedTokens: 5_000, WindowTokens: 262_144 }, Title: null, SpeedMeasurement: null },
                  "kimi-cli: an open tool turn read cold lost its tool, output, configured model, project from kimi.json or context window");
            var child = rows.FirstOrDefault(r => r.IsSubagent);
            check(child is { ParentSessionID: "legacy-session", AgentID: "a1234567", AgentRole: "coder", Model: "kimi-k2-sub",
                      ActivityState: TokenActivityState.Complete, LastOutputTokens: 7 },
                  "kimi-cli: a subagent was not grouped under its session with its meta.json type and model");
            check(!rows.Any(r => r.SessionID == "migrated-session"), "kimi-cli: a session already migrated to Kimi Code was listed twice");
            Append(mainWire,
                Legacy("ToolResult", 6, """{"tool_call_id":"tc1","return_value":{"output":"PRIVATE_OUTPUT","is_error":false}}"""),
                Status(6, 30, "m1"),
                Legacy("ToolCall", 7, """{"type":"function","id":"tc2","function":{"name":"Shell","arguments":"PRIVATE"}}"""),
                Legacy("ApprovalRequest", 7, """{"id":"ap1","tool_call_id":"tc2","sender":"Shell","action":"PRIVATE","description":"PRIVATE_DESCRIPTION"}"""));
            now = Start.AddSeconds(3_600);
            row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { ActivityState: TokenActivityState.Input, Active: true, CurrentTurnOutputTokens: 30 },
                  "kimi-cli: an approval request was not live input, or a repeated StatusUpdate was counted twice");
            // The next step's response reuses the id "m1", as some OpenAI-compatible gateways do for every response.
            Append(mainWire,
                Legacy("ApprovalResponse", 3_601, """{"request_id":"ap1","response":"approve","feedback":""}"""),
                Legacy("ToolResult", 3_602, """{"tool_call_id":"tc2","return_value":{"output":"PRIVATE"}}"""),
                Legacy("StepBegin", 3_602, """{"n":2}"""), Status(3_603, 20, "m1"), Legacy("TurnEnd", 3_604));
            now = Start.AddSeconds(3_605);
            rows = tracker.Sample();
            row = rows.FirstOrDefault(r => !r.IsSubagent);
            check(row is { ActivityState: TokenActivityState.Complete, Active: false, LastOutputTokens: 50 }
                  && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([20]),
                  "kimi-cli: TurnEnd did not finish the turn with its whole output, or a later step reusing a response id was dropped");
            check(!Encoded(rows).Contains("PRIVATE", StringComparison.Ordinal), "kimi-cli: transcript text leaked into a reading");
            check(KimiLog.ConfiguredModel("default_model = 'a'\n[models.a]\nmodel = \"kimi-code/m\"\n") == "m"
                  && KimiLog.ConfiguredModel("default_model = \"missing\"\n[models.a]\nmodel = \"x\"\n") is null
                  && KimiLog.ConfiguredModel(JsonDocument.Parse("""{"default_model":"a","models":{"a":{"model":"json-model"}}}""").RootElement) == "json-model"
                  && KimiLog.WorkDirFolder("/tmp/KimiLegacy", "ssh").StartsWith("ssh_", StringComparison.Ordinal),
                  "kimi-cli: the configured model or a remote work directory's folder name was misread");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            check(false, $"kimi-cli fixtures could not be written: {error.Message}");
        }
    }
}
