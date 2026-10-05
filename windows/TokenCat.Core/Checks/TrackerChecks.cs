using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace TokenCat;

/// TrackerChecks.swift: synthetic metadata-only regressions, descriptions verbatim, then the Windows cases from DESIGN
/// WP1 (C:\ cwd, backslash hints, CRLF, a writer that keeps the log open). No network calls, accounts, or actual
/// transcript text; temp homes only.
public static class TrackerChecks
{
    static JsonNode N(string json) => JsonNode.Parse(json)!;
    static JsonObject J(string json) => N(json).AsObject();
    /// JSON templates with `<name>` holes: interpolated raw strings can't hold JSON's runs of closing braces.
    static string Fill(string template, params (string Hole, object Value)[] values) =>
        values.Aggregate(template, (text, pair) => text.Replace(pair.Hole, Convert.ToString(pair.Value, CultureInfo.InvariantCulture), StringComparison.Ordinal));
    static byte[] Line(JsonNode value) => [.. Encoding.UTF8.GetBytes(value.ToJsonString(Json.Options)), 10];
    static byte[] Lines(params JsonNode[] values) => [.. values.SelectMany(Line)];
    static byte[] Spaces(int count) => [.. Enumerable.Repeat((byte)32, count), 10];
    static void Feed(TokenLogParser parser, JsonNode value) => parser.Consume(Line(value));
    static DateTimeOffset At(string iso) => DateTimeOffset.Parse(iso, CultureInfo.InvariantCulture);
    static bool SetIs(IEnumerable<string?> values, params string[] expected) => values.OfType<string>().ToHashSet().SetEquals(expected);

    static JsonObject Merged(JsonObject record, string extras)
    {
        foreach (var (key, value) in J(extras)) record[key] = value?.DeepClone();
        return record;
    }

    static JsonObject Codex(string type, string timestamp, string extras = "{}") =>
        new() { ["timestamp"] = timestamp, ["type"] = "event_msg", ["payload"] = Merged(new JsonObject { ["type"] = type }, extras) };

    static JsonObject Usage(int total, int last, string timestamp) => Codex("token_count", timestamp, Fill("""
        {"info":{"total_token_usage":{"output_tokens":<total>,"input_tokens":90000,"cached_input_tokens":80000,"reasoning_output_tokens":<total / 2>},"last_token_usage":{"output_tokens":<last>,"input_tokens":90000}}}
        """, ("<total>", total), ("<total / 2>", total / 2), ("<last>", last)));

    static JsonObject Assistant(string id, int count, string timestamp, string uuid) => J(Fill("""
        {"type":"assistant","timestamp":"<timestamp>","uuid":"<uuid>","message":{"id":"<id>","model":"fixture-model","usage":{"output_tokens":<count>,"input_tokens":60000,"cache_creation_input_tokens":40000,"cache_read_input_tokens":50000}}}
        """, ("<timestamp>", timestamp), ("<uuid>", uuid), ("<id>", id), ("<count>", count)));

    static JsonObject UsageRecord(string response, string turn, int output, int turnTotal, string timestamp) => J(Fill("""
        {"type":"token_usage_record","timestamp":"<timestamp>","payload":{"turn_id":"<turn>","response_id":"<response>","usage":{"output_tokens":<output>,"input_tokens":90000},"turn_token_usage":{"output_tokens":<turnTotal>,"input_tokens":900000},"thread_token_usage":{"output_tokens":<turnTotal + 10_000>}}}
        """, ("<timestamp>", timestamp), ("<turn>", turn), ("<response>", response), ("<output>", output), ("<turnTotal>", turnTotal), ("<turnTotal + 10_000>", turnTotal + 10_000)));

    static JsonObject ClaudeUser(string uuid, string timestamp, JsonNode? content, string extra = "{}") =>
        Merged(new JsonObject { ["type"] = "user", ["uuid"] = uuid, ["timestamp"] = timestamp, ["message"] = new JsonObject { ["content"] = content } }, extra);

    static JsonObject ClaudeReply(string id, int count, string timestamp, string uuid, string blocks, string? stop = null, string model = "fixture-model")
    {
        var message = new JsonObject { ["id"] = id, ["model"] = model, ["usage"] = new JsonObject { ["output_tokens"] = count }, ["content"] = N(blocks) };
        if (stop is not null) message["stop_reason"] = stop;
        return new JsonObject { ["type"] = "assistant", ["timestamp"] = timestamp, ["uuid"] = uuid, ["message"] = message };
    }

    static JsonObject Limited(string timestamp, double used, long resets, int input, string limit = "codex") => Codex("token_count", timestamp, Fill("""
        {"info":{"total_token_usage":{"output_tokens":10},"last_token_usage":{"output_tokens":10,"input_tokens":<input>},"model_context_window":258400},"rate_limits":{"limit_id":"<limit>","primary":{"used_percent":<used>,"window_minutes":10080,"resets_at":<resets>},"secondary":null,"credits":{"balance":"PRIVATE_BALANCE"}}}
        """, ("<input>", input), ("<limit>", limit), ("<used>", used), ("<resets>", resets)));

    public static List<string> Run()
    {
        var c = new Check("Tracker");
        void check(bool valid, string description) => c.That(valid, description);

        var parser = new TokenLogParser(TokenSource.Codex);
        Feed(parser, Usage(1_000, 30, "2026-10-04T01:00:00Z"));
        Feed(parser, Codex("task_started", "2026-10-04T01:00:01Z", """{"turn_id":"turn-a"}"""));
        Feed(parser, Usage(1_100, 100, "2026-10-04T01:00:02.500Z"));
        Feed(parser, Usage(1_100, 100, "2026-10-04T01:00:02.600Z"));
        Feed(parser, Usage(1_150, 50, "2026-10-04T01:00:03Z"));
        Feed(parser, Codex("task_complete", "2026-10-04T01:00:04Z", """{"turn_id":"turn-a","duration_ms":3000}"""));
        check(parser.Completion?.Output == 150, "Codex: duplicate cumulative usage or cache/reasoning was counted twice");
        check(parser.Completion?.DurationSeconds == 3 && parser.LastTurnDuration == 3,
              "Codex: the client-reported turn duration must be kept apart from its output");
        Feed(parser, Codex("task_started", "2026-10-04T01:00:05Z", """{"turn_id":"turn-a"}"""));
        check(!parser.IsActive(At("2026-10-04T01:00:05Z")), "Codex: replayed completed turn reopened");

        var compacted = new TokenLogParser(TokenSource.Codex);
        Feed(compacted, Codex("task_started", "2026-10-04T02:00:00Z", """{"turn_id":"compact"}"""));
        Feed(compacted, Usage(100, 100, "2026-10-04T02:00:01Z"));
        Feed(compacted, Usage(20, 20, "2026-10-04T02:00:02Z"));
        Feed(compacted, Usage(60, 40, "2026-10-04T02:00:03Z"));
        Feed(compacted, Codex("task_complete", "2026-10-04T02:00:04Z", """{"turn_id":"compact","duration_ms":4000}"""));
        check(compacted.Completion?.Output == 160, "Codex: cumulative reset during compaction");
        var tail = new TokenLogParser(TokenSource.Codex);
        Feed(tail, Usage(900, 50, "2026-10-04T02:00:01Z"));
        Feed(tail, Codex("task_complete", "2026-10-04T02:00:02Z", """{"turn_id":"missing","duration_ms":2000}"""));
        check(tail.Completion == null, "Codex: missing turn start invented a speed");

        var forked = new TokenLogParser(TokenSource.Codex);
        Feed(forked, J("""{"type":"session_meta","payload":{"id":"child-session","cwd":"/tmp/ChildProject","timestamp":"2026-10-04T02:00:10Z","source":{"subagent":{"parent_thread_id":"parent"}},"agent_path":"/root/child"}}"""));
        Feed(forked, Codex("task_started", "2026-10-04T02:00:11Z", """{"turn_id":"parent-turn","started_at":"2026-10-04T02:00:00Z"}"""));
        Feed(forked, Usage(100, 100, "2026-10-04T02:00:12Z"));
        Feed(forked, Codex("task_complete", "2026-10-04T02:00:13Z", """{"turn_id":"parent-turn","duration_ms":13000}"""));
        check(forked.Completion == null && forked.LastActivity == null && forked.LatestOutput == null,
              "Forked Codex session inherited parent turn usage or activity");
        Feed(forked, J("""{"type":"turn_context","payload":{"model":"child-model","turn_id":"child-turn"}}"""));
        Feed(forked, Codex("task_started", "2026-10-04T02:00:14Z", """{"turn_id":"child-turn"}"""));
        Feed(forked, Usage(120, 20, "2026-10-04T02:00:14.500Z"));
        Feed(forked, Codex("task_complete", "2026-10-04T02:00:15Z", """{"turn_id":"child-turn","duration_ms":1000}"""));
        check(forked.IsSubagent && forked.Completion?.Output == 20 && forked.LastTurnDuration == 1
              && forked.Model == "child-model" && forked.Completion?.Model == "child-model",
              "Forked Codex session failed to measure its own first turn independently");

        var claude = new TokenLogParser(TokenSource.Claude);
        Feed(claude, J("""{"type":"user","uuid":"human","timestamp":"2026-10-04T03:00:00Z","message":{"content":[{"type":"text"}]}}"""));
        Feed(claude, Assistant("msg-a", 100, "2026-10-04T03:00:01.500Z", "a1"));
        Feed(claude, Assistant("msg-a", 150, "2026-10-04T03:00:02Z", "a2"));
        Feed(claude, J("""{"type":"user","uuid":"tool","timestamp":"2026-10-04T03:00:03Z","message":{"content":[{"type":"tool_result"}]}}"""));
        Feed(claude, Assistant("msg-b", 50, "2026-10-04T03:00:04Z", "b"));
        Feed(claude, Assistant("msg-b", 50, "2026-10-04T03:00:04.500Z", "b2"));
        Feed(claude, J("""{"type":"system","subtype":"turn_duration","parentUuid":"b2","timestamp":"2026-10-04T03:00:05Z","durationMs":5000}"""));
        check(claude.Completion?.Output == 200, "Claude: message ID maximum usage or tool-result boundary");
        check(claude.Completion?.DurationSeconds == 5 && claude.Context?.UsedTokens == 150_000 && claude.Context?.WindowTokens == null,
              "Claude: durationMs or the absolute input-side context (input + cache) was not kept");
        Feed(claude, J("""{"type":"user","uuid":"human2","timestamp":"2026-10-04T03:01:00Z","message":{"content":[{"type":"text"}]}}"""));
        Feed(claude, Assistant("msg-a", 150, "2026-10-04T03:01:01Z", "old"));
        Feed(claude, Assistant("msg-c", 30, "2026-10-04T03:01:02Z", "c"));
        Feed(claude, J("""{"type":"system","subtype":"turn_duration","parentUuid":"c","timestamp":"2026-10-04T03:01:03Z","durationMs":3000}"""));
        check(claude.Completion?.Output == 30, "Claude: prior-turn message replay leaked into a new turn");
        var unknown = new TokenLogParser(TokenSource.Claude);
        Feed(unknown, J("""{"type":"user","uuid":"human","timestamp":"2026-10-04T03:00:00Z","message":{"content":[{"type":"text"}]}}"""));
        Feed(unknown, Assistant("msg", 100, "2026-10-04T03:00:02Z", "out"));
        Feed(unknown, J("""{"type":"system","subtype":"turn_duration","timestamp":"2026-10-04T03:00:03Z"}"""));
        check(unknown.Completion?.Output == 100 && unknown.Completion?.DurationSeconds == null && unknown.LastTurnDuration == null,
              "Claude: a missing durationMs must stay unknown rather than come from log times");
        check(!unknown.IsActive(At("2026-10-04T04:00:03Z")), "Old unfinished turn stayed active");
        var claudeTail = new TokenLogParser(TokenSource.Claude);
        Feed(claudeTail, Assistant("tail", 100, "2026-10-04T03:00:02Z", "out"));
        Feed(claudeTail, J("""{"type":"system","subtype":"turn_duration","timestamp":"2026-10-04T03:00:03Z","durationMs":3000}"""));
        check(claudeTail.Completion == null, "Claude: unknown tail start invented a complete turn");

        var liveCodex = new TokenLogParser(TokenSource.Codex);
        var liveStart = At("2026-10-04T03:00:00Z");
        Feed(liveCodex, Codex("task_started", "2026-10-04T03:00:00Z", """{"turn_id":"live-codex"}"""));
        check(liveCodex.CurrentTurnStartedAt == liveStart && liveCodex.CurrentTurnOutputTokens == 0
              && liveCodex.ActivityState(liveStart) == TokenActivityState.Working && liveCodex.LastOutputDelta == null,
              "Codex live: a newly observed turn must start at zero with no previous output chunk");
        Feed(liveCodex, Usage(100, 100, "2026-10-04T03:00:01Z"));
        Feed(liveCodex, Usage(100, 100, "2026-10-04T03:00:02Z"));
        check(liveCodex.CurrentTurnOutputTokens == 100 && liveCodex.LastOutputDelta == 100 && liveCodex.LastOutputAt == liveStart.AddSeconds(1),
              "Codex live: duplicate cumulative usage must not refresh or multiply output delta");
        foreach (var id in (string[])["tool-a", "tool-b"])
            Feed(liveCodex, J(Fill("""{"type":"response_item","timestamp":"2026-10-04T03:00:03Z","payload":{"type":"function_call","call_id":"<id>"}}""", ("<id>", id))));
        Feed(liveCodex, J("""{"type":"response_item","timestamp":"2026-10-04T03:00:04Z","payload":{"type":"function_call_output","call_id":"tool-a"}}"""));
        check(liveCodex.ActivityState(liveStart.AddSeconds(4)) == TokenActivityState.Tool,
              "Codex live: one completed tool must not clear another outstanding call");
        Feed(liveCodex, J("""{"type":"response_item","timestamp":"2026-10-04T03:00:05Z","payload":{"type":"function_call_output","call_id":"tool-b"}}"""));
        check(liveCodex.ActivityState(liveStart.AddSeconds(5)) == TokenActivityState.Working,
              "Codex live: matching final tool result should return to working state");
        check(liveCodex.ActivityState(liveStart.AddSeconds(300)) == TokenActivityState.Working && liveCodex.IsActive(liveStart.AddSeconds(300)),
              "Codex live: a long model wait (no tool pending) must stay running within ten minutes");
        check(liveCodex.ActivityState(liveStart.AddSeconds(700)) == TokenActivityState.Stale
              && liveCodex.CurrentTurnStartedAt == liveStart && liveCodex.CurrentTurnOutputTokens == 100,
              "Codex live: stale logs must keep elapsed time without claiming completion");
        check(liveCodex.ActivityState(liveStart.AddSeconds(2_000)) == TokenActivityState.Unfinished && !liveCodex.IsActive(liveStart.AddSeconds(2_000)),
              "Codex live: an open turn silent for over 30 minutes must not stay in the waiting state");
        Feed(liveCodex, Codex("task_complete", "2026-10-04T03:00:06Z", """{"turn_id":"live-codex","duration_ms":6000}"""));
        check(liveCodex.CurrentTurnStartedAt == null && liveCodex.CurrentTurnOutputTokens == null
              && liveCodex.ActivityState(liveStart.AddSeconds(6)) == TokenActivityState.Complete,
              "Codex live: completed turns must clear current-turn counters");
        Feed(liveCodex, Codex("task_started", "2026-10-04T03:00:07Z", """{"turn_id":"next-codex"}"""));
        check(liveCodex.CurrentTurnOutputTokens == 0 && liveCodex.LastOutputAt == null && liveCodex.LastOutputDelta == null,
              "Codex live: a new turn leaked the previous turn's output delta");
        Feed(liveCodex, Codex("turn_aborted", "2026-10-04T03:00:08Z", """{"turn_id":"next-codex"}"""));
        check(liveCodex.ActivityState(liveStart.AddSeconds(8)) == TokenActivityState.Interrupted
              && liveCodex.CurrentTurnStartedAt == null && liveCodex.CurrentTurnOutputTokens == null,
              "Codex live: interrupted turn state or current counters were not cleared");
        var unknownLiveCount = new TokenLogParser(TokenSource.Codex);
        Feed(unknownLiveCount, Codex("task_started", "2026-10-04T03:00:00Z", """{"turn_id":"unknown-count"}"""));
        Feed(unknownLiveCount, Codex("token_count", "2026-10-04T03:00:01Z", """{"info":{"total_token_usage":{"output_tokens":"unavailable"}}}"""));
        check(unknownLiveCount.CurrentTurnOutputTokens == null && unknownLiveCount.LastOutputDelta == null,
              "Codex live: an unrecognized output counter must remain unknown, not fall back to zero");

        var recorded = new TokenLogParser(TokenSource.Codex);
        Feed(recorded, Usage(10_000, 300, "2026-10-04T05:00:00Z"));
        Feed(recorded, Codex("task_started", "2026-10-04T05:00:01Z", """{"turn_id":"usage-turn"}"""));
        Feed(recorded, UsageRecord("resp-1", "usage-turn", 120, 120, "2026-10-04T05:00:02Z"));
        Feed(recorded, J("""{"type":"response_item","timestamp":"2026-10-04T05:00:02Z","payload":{"type":"function_call","call_id":"long-tool"}}"""));
        var usageStart = At("2026-10-04T05:00:02Z");
        check(recorded.CurrentTurnOutputTokens == 120 && recorded.LastOutputDelta == 120
              && recorded.LastOutputAt == usageStart && recorded.RecentOutputs.LastOrDefault().Tokens == 120,
              "Codex usage record: a response must count before its tool finishes and token_count arrives");
        Feed(recorded, J("""{"type":"response_item","timestamp":"2026-10-04T05:03:00Z","payload":{"type":"function_call_output","call_id":"long-tool"}}"""));
        Feed(recorded, Usage(10_120, 120, "2026-10-04T05:03:00Z"));
        Feed(recorded, UsageRecord("resp-1", "usage-turn", 120, 120, "2026-10-04T05:03:01Z"));
        check(recorded.CurrentTurnOutputTokens == 120 && recorded.LastOutputAt == usageStart
              && recorded.RecentOutputs.Count(e => e.At >= usageStart) == 1,
              "Codex usage record: the delayed token_count or a repeated response_id was counted again");
        Feed(recorded, UsageRecord("resp-compact", "usage-turn", 4_000, 4_120, "2026-10-04T05:03:02Z"));
        Feed(recorded, Usage(10_120, 0, "2026-10-04T05:03:02Z"));
        Feed(recorded, UsageRecord("resp-other", "foreign-turn", 999, 999, "2026-10-04T05:03:03Z"));
        check(recorded.CurrentTurnOutputTokens == 4_120 && recorded.LastOutputDelta == 4_000,
              "Codex usage record: compaction output was dropped, or another turn's record leaked into the open turn");
        Feed(recorded, Codex("task_complete", "2026-10-04T05:03:05Z", """{"turn_id":"usage-turn","duration_ms":184000}"""));
        check(recorded.Completion?.Output == 4_120 && recorded.CurrentTurnOutputTokens == null,
              "Codex usage record: completed turn must report the recorded turn total and clear live counters");

        var inheritedUsage = new TokenLogParser(TokenSource.Codex);
        Feed(inheritedUsage, J("""{"type":"session_meta","payload":{"id":"fork","timestamp":"2026-10-04T05:10:00Z","source":{"subagent":{"parent_thread_id":"parent"}}}}"""));
        Feed(inheritedUsage, Codex("task_started", "2026-10-04T05:10:01Z", """{"turn_id":"parent-turn","started_at":"2026-10-04T05:00:00Z"}"""));
        Feed(inheritedUsage, UsageRecord("parent-resp", "parent-turn", 500, 500, "2026-10-04T05:10:01Z"));
        check(inheritedUsage.LastOutputDelta == null && inheritedUsage.RecentOutputs.Count == 0 && inheritedUsage.LastActivity == null,
              "Codex usage record: an inherited parent response was counted in a forked log");

        // Liveness horizons: Codex tools yield quickly; any record keeps a turn alive.
        var toolWait = new TokenLogParser(TokenSource.Codex);
        Feed(toolWait, Codex("task_started", "2026-10-04T06:00:00Z", """{"turn_id":"tool-wait"}"""));
        Feed(toolWait, J("""{"type":"response_item","timestamp":"2026-10-04T06:00:01Z","payload":{"type":"function_call","call_id":"stuck"}}"""));
        var toolWaitStart = At("2026-10-04T06:00:00Z");
        check(toolWait.ActivityState(toolWaitStart.AddSeconds(150)) == TokenActivityState.Stale,
              "Codex liveness: a tool silent past its 120 s horizon must become log-waiting");
        Feed(toolWait, J("""{"type":"world_state","timestamp":"2026-10-04T06:08:00Z","payload":{"full":true}}"""));
        check(toolWait.IsActive(toolWaitStart.AddSeconds(530)) && toolWait.LastActivity == toolWaitStart.AddSeconds(1),
              "Codex liveness: any newer record must keep the turn alive without becoming content activity");
        // Codex plan-mode questions block on the person; the async variant returns at once.
        foreach (var (name, waits) in new[] { ("request_user_input", true), ("request_user_input_async", false) })
        {
            var question = new TokenLogParser(TokenSource.Codex);
            Feed(question, Codex("task_started", "2026-10-04T06:00:00Z", """{"turn_id":"question"}"""));
            Feed(question, J(Fill("""{"type":"response_item","timestamp":"2026-10-04T06:00:01Z","payload":{"type":"function_call","call_id":"q","name":"<name>","arguments":"PRIVATE_INPUT"}}""", ("<name>", name))));
            var state = question.ActivityState(toolWaitStart.AddSeconds(600));
            check(waits ? state == TokenActivityState.Input && question.IsActive(toolWaitStart.AddSeconds(600)) : state == TokenActivityState.Stale,
                  $"Codex input state: {name} must {(waits ? "wait for the person" : "follow the 120 s tool horizon")}");
        }

        var closeStart = At("2026-10-04T07:00:00Z");
        var workflowAgent = new TokenLogParser(TokenSource.Claude, isSubagent: true);
        Feed(workflowAgent, ClaudeUser("w-in", "2026-10-04T07:00:00Z", "task", """{"isSidechain":true}"""));
        Feed(workflowAgent, ClaudeReply("w-msg", 80, "2026-10-04T07:00:02Z", "w-out", """[{"type":"tool_use","id":"w-tool"}]""", stop: "tool_use"));
        Feed(workflowAgent, ClaudeUser("w-end", "2026-10-04T07:00:03Z", N("""[{"type":"tool_result","tool_use_id":"w-tool"}]"""),
                                       """{"isSidechain":true,"toolEndsTurn":true}"""));
        check(workflowAgent.ActivityState(closeStart.AddSeconds(4)) == TokenActivityState.Complete
              && !workflowAgent.IsActive(closeStart.AddSeconds(4)) && workflowAgent.CurrentTurnStartedAt == null,
              "Claude close: a workflow agent's turn-ending tool result must complete it");

        var replied = new TokenLogParser(TokenSource.Claude);
        Feed(replied, ClaudeUser("r-in", "2026-10-04T07:00:00Z", "hello", """{"origin":{"kind":"human"}}"""));
        Feed(replied, ClaudeReply("r-msg", 40, "2026-10-04T07:00:02Z", "r-out", """[{"type":"text"}]""", stop: "end_turn"));
        check(replied.ActivityState(closeStart.AddSeconds(3)) == TokenActivityState.Complete && replied.CurrentTurnOutputTokens == null,
              "Claude close: a final reply without tool use must close the turn even without a stop marker");
        Feed(replied, ClaudeReply("r-more", 25, "2026-10-04T07:00:05Z", "r-more", """[{"type":"text"}]"""));
        check(replied.IsActive(closeStart.AddSeconds(6)) && replied.CurrentTurnOutputTokens == 65 && replied.CurrentTurnStartedAt == closeStart,
              "Claude close: output after a final reply (blocking Stop hook) must reopen the same turn");
        Feed(replied, J("""{"type":"system","subtype":"stop_hook_summary","parentUuid":"unseen-attachment","timestamp":"2026-10-04T07:00:06Z"}"""));
        check(replied.ActivityState(closeStart.AddSeconds(7)) == TokenActivityState.Complete && !replied.IsActive(closeStart.AddSeconds(7)),
              "Claude close: a stop marker whose parent is an attachment must still end the turn");
        Feed(replied, ClaudeUser("r-cmd", "2026-10-04T07:01:00Z", "<command-name>/compact</command-name>"));
        check(replied.CurrentTurnStartedAt == null && replied.ActivityState(closeStart.AddSeconds(61)) == TokenActivityState.Complete,
              "Claude close: a local slash-command echo must not open a turn");
        Feed(replied, ClaudeUser("r-note", "2026-10-04T07:02:00Z", "done", """{"origin":{"kind":"task-notification"}}"""));
        check(replied.CurrentTurnStartedAt == closeStart.AddSeconds(120), "Claude close: a task notification prompt must start a turn");
        Feed(replied, ClaudeReply("r-err", 0, "2026-10-04T07:02:01Z", "r-err", """[{"type":"text"}]""", stop: "stop_sequence", model: "<synthetic>"));
        check(replied.ActivityState(closeStart.AddSeconds(122)) == TokenActivityState.Interrupted && replied.Model == "fixture-model",
              "Claude close: an API error reply must interrupt the turn without replacing the model");
        Feed(replied, ClaudeUser("r-again", "2026-10-04T07:03:00Z", "again", """{"origin":{"kind":"human"}}"""));
        Feed(replied, ClaudeUser("r-stop", "2026-10-04T07:03:01Z", N("""[{"type":"text","text":"[Request interrupted by user]"}]""")));
        check(replied.ActivityState(closeStart.AddSeconds(182)) == TokenActivityState.Interrupted && replied.CurrentTurnStartedAt == null,
              "Claude close: an interruption notice must end the turn rather than start a new one");

        var replayed = new TokenLogParser(TokenSource.Claude);
        Feed(replayed, ClaudeUser("p-in", "2026-10-04T08:00:00Z", "first", """{"origin":{"kind":"human"}}"""));
        Feed(replayed, ClaudeReply("p-msg", 30, "2026-10-04T08:00:01Z", "p-a", """[{"type":"thinking"}]""", stop: "tool_use"));
        Feed(replayed, ClaudeReply("p-msg", 30, "2026-10-04T08:00:04Z", "p-b", """[{"type":"tool_use","id":"p-tool"}]""", stop: "tool_use"));
        var replayStart = At("2026-10-04T08:00:00Z");
        check(replayed.CurrentTurnOutputTokens == 30 && replayed.LastOutputAt == replayStart.AddSeconds(4)
              && replayed.RecentOutputs.Count == 1 && replayed.RecentOutputs[^1].At == replayStart.AddSeconds(4),
              "Claude freshness: later blocks of one message must move its record time without counting again");
        Feed(replayed, ClaudeUser("old-in", "2026-10-04T07:00:00Z", "restored", """{"origin":{"kind":"human"}}"""));
        Feed(replayed, ClaudeUser("p-in", "2026-10-04T08:00:00Z", "first", """{"origin":{"kind":"human"}}"""));
        check(replayed.CurrentTurnStartedAt == replayStart && replayed.CurrentTurnOutputTokens == 30
              && replayed.ActivityState(replayStart.AddSeconds(5)) == TokenActivityState.Tool,
              "Claude replay: re-appended history must not rewind the open turn");
        byte[] oversized = [.. "{\"parentUuid\":\"p-b\",\"isSidechain\":false,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"p-tool\",\"type\":\"tool_result\",\"content\":\""u8.ToArray(),
                            .. Enumerable.Repeat((byte)120, 20_000)];
        replayed.ConsumeOversizedPrefix(oversized.AsSpan(0, 16_384));
        check(replayed.ActivityState(replayStart.AddSeconds(6)) == TokenActivityState.Working,
              "Oversized tool result: the call named in its prefix must stop counting as a running tool");

        var liveClaude = new TokenLogParser(TokenSource.Claude);
        Feed(liveClaude, J("""{"type":"user","uuid":"live-human","timestamp":"2026-10-04T03:00:00Z","message":{"content":[{"type":"text"}]}}"""));
        var partialUsage = Assistant("partial-msg", 3, "2026-10-04T03:00:01Z", "partial");
        partialUsage["message"]!["content"] = N("""[{"type":"thinking"}]""");
        Feed(liveClaude, partialUsage);
        var finalUsage = Assistant("partial-msg", 264, "2026-10-04T03:00:02Z", "final");
        finalUsage["message"]!["content"] = N("""[{"type":"tool_use","id":"claude-tool"}]""");
        Feed(liveClaude, finalUsage);
        Feed(liveClaude, finalUsage);
        check(liveClaude.CurrentTurnOutputTokens == 264 && liveClaude.LastOutputDelta == 261
              && liveClaude.ActivityState(liveStart.AddSeconds(2)) == TokenActivityState.Tool,
              "Claude live: progressive 3→264 usage must add 261 once, not keep the first fragment or double-count final usage");
        Feed(liveClaude, J("""{"type":"user","uuid":"live-result","timestamp":"2026-10-04T03:00:03Z","message":{"content":[{"type":"tool_result","tool_use_id":"claude-tool"}]}}"""));
        check(liveClaude.ActivityState(liveStart.AddSeconds(3)) == TokenActivityState.Working
              && liveClaude.CurrentTurnOutputTokens == 264 && liveClaude.CurrentTurnStartedAt == liveStart,
              "Claude live: a tool result must preserve the human turn's output and elapsed-time origin");
        Feed(liveClaude, J("""{"type":"system","subtype":"turn_duration","parentUuid":"final","timestamp":"2026-10-04T03:00:04Z","durationMs":4000}"""));
        check(liveClaude.ActivityState(liveStart.AddSeconds(4)) == TokenActivityState.Complete
              && liveClaude.CurrentTurnOutputTokens == null && liveClaude.CurrentTurnStartedAt == null,
              "Claude live: an actual completion must clear current-turn metadata");
        Feed(liveClaude, J("""{"type":"user","uuid":"next-human","timestamp":"2026-10-04T03:00:05Z","message":{"content":[{"type":"text"}]}}"""));
        check(liveClaude.LastOutputDelta == null && liveClaude.LastOutputAt == null && liveClaude.CurrentTurnOutputTokens == 0,
              "Claude live: new human input must reset the previous output chunk");
        var confirmedBeforeInterruption = liveClaude.Completion;
        var interruptedCandidate = Assistant("interrupted-candidate", 1_000, "2026-10-04T03:00:06Z", "candidate");
        interruptedCandidate["parentUuid"] = "next-human";
        interruptedCandidate["requestId"] = "interrupted-request";
        interruptedCandidate["message"]!["stop_reason"] = "tool_use";
        interruptedCandidate["message"]!["content"] = N("""[{"type":"tool_use","id":"interrupted-tool"}]""");
        Feed(liveClaude, interruptedCandidate);
        Feed(liveClaude, J("""{"type":"system","subtype":"interrupted","timestamp":"2026-10-04T03:00:07Z"}"""));
        Feed(liveClaude, J("""{"type":"user","uuid":"after-interruption","timestamp":"2026-10-04T03:00:08Z","message":{"content":[{"type":"text"}]}}"""));
        var completionAfterNewInput = liveClaude.Completion;
        Feed(liveClaude, Assistant("recovered-response", 10, "2026-10-04T03:00:10Z", "recovered"));
        Feed(liveClaude, J("""{"type":"system","subtype":"turn_duration","parentUuid":"recovered","timestamp":"2026-10-04T03:00:10Z","durationMs":2000}"""));
        check(completionAfterNewInput?.Output == confirmedBeforeInterruption?.Output
              && completionAfterNewInput?.FinishedAt == confirmedBeforeInterruption?.FinishedAt
              && liveClaude.Completion?.Output == 10 && liveClaude.LastTurnDuration == 2,
              "Claude interruption promoted an unconfirmed response candidate or damaged the next valid turn");

        var estimated = new TokenLogParser(TokenSource.Claude);
        Feed(estimated, J("""{"type":"user","uuid":"input","timestamp":"2026-10-04T03:00:00Z","message":{"content":[{"type":"tool_result"}]}}"""));
        Feed(estimated, J("""{"type":"attachment","uuid":"attached","parentUuid":"input","timestamp":"2026-10-04T03:00:00.010Z"}"""));
        var thought = Assistant("estimated", 200, "2026-10-04T03:00:01Z", "thought");
        thought["parentUuid"] = "attached";
        thought["requestId"] = "request";
        thought["message"]!["stop_reason"] = "tool_use";
        thought["message"]!["content"] = N("""[{"type":"thinking"}]""");
        Feed(estimated, thought);
        check(estimated.Completion == null, "Claude estimate: full usage on an early thinking fragment exposed a speed");
        var terminal = Assistant("estimated", 200, "2026-10-04T03:00:04Z", "terminal");
        terminal["parentUuid"] = "thought";
        terminal["requestId"] = "request";
        terminal["message"]!["stop_reason"] = "tool_use";
        terminal["message"]!["content"] = N("""[{"type":"tool_use"}]""");
        Feed(estimated, terminal);
        check(estimated.Completion == null, "Claude estimate: an unconfirmed streaming fragment exposed a speed");
        Feed(estimated, J("""{"type":"user","uuid":"tool-next","parentUuid":"terminal","timestamp":"2026-10-04T03:00:10Z","message":{"content":[{"type":"tool_result"}]}}"""));
        check(estimated.Completion == null && estimated.LatestOutput == 200,
              "Claude log timestamps must not invent a generation speed while confirmed tokens remain available");
        Feed(estimated, J("""{"type":"system","subtype":"stop_hook_summary","parentUuid":"terminal","timestamp":"2026-10-04T03:00:11Z"}"""));
        check(estimated.Completion == null && estimated.ActivityState(liveStart.AddSeconds(11)) == TokenActivityState.Complete,
              "Claude stop without measured duration must close the turn without inventing a speed");
        var unanchored = new TokenLogParser(TokenSource.Claude);
        Feed(unanchored, terminal);
        Feed(unanchored, J("""{"type":"system","subtype":"stop_hook_summary","parentUuid":"terminal","timestamp":"2026-10-04T03:00:05Z"}"""));
        check(unanchored.Completion == null, "Claude estimate: tail without observed input ancestry invented request start");

        // Waiting for the person: a pending question never goes stale, but is capped at 24 hours.
        var asking = new TokenLogParser(TokenSource.Claude);
        var askStart = At("2026-10-04T09:00:00Z");
        Feed(asking, ClaudeUser("k-in", "2026-10-04T09:00:00Z", "plan", """{"origin":{"kind":"human"}}"""));
        Feed(asking, ClaudeReply("k-msg", 20, "2026-10-04T09:00:01Z", "k-out",
                                 """[{"type":"tool_use","id":"k-bash","name":"Bash","input":{"command":"PRIVATE_INPUT"}}]"""));
        check(asking.ActivityState(askStart.AddSeconds(2)) == TokenActivityState.Tool && asking.RunningTool?.Name == "Bash"
              && TokenLogParser.Category("Bash") == ToolCategory.Command,
              "Input state: a running command was not named by its tool category");
        Feed(asking, ClaudeReply("k-ask", 10, "2026-10-04T09:00:02Z", "k-ask", """[{"type":"tool_use","id":"k-question","name":"AskUserQuestion"}]"""));
        check(asking.ActivityState(askStart.AddSeconds(3_600)) == TokenActivityState.Input
              && asking.IsActive(askStart.AddSeconds(3_600)) && asking.RunningTool?.Name == "AskUserQuestion",
              "Input state: a pending question must stay waiting-for-input instead of becoming log-waiting");
        check(asking.ActivityState(askStart.AddSeconds(86_500)) == TokenActivityState.Unfinished && !asking.IsActive(askStart.AddSeconds(86_500)),
              "Input state: a question with no log for over 24 hours must become unfinished");
        Feed(asking, ClaudeUser("k-answer", "2026-10-04T09:05:00Z", N("""[{"type":"tool_result","tool_use_id":"k-question"}]""")));
        check(asking.ActivityState(askStart.AddSeconds(301)) == TokenActivityState.Tool && asking.RunningTool?.Name == "Bash",
              "Input state: answering the question must return to the still-running tool");
        var planning = new TokenLogParser(TokenSource.Claude);
        Feed(planning, ClaudeUser("pl-in", "2026-10-04T09:00:00Z", "plan", """{"origin":{"kind":"human"}}"""));
        Feed(planning, ClaudeReply("pl-msg", 5, "2026-10-04T09:00:01Z", "pl-out", """[{"type":"tool_use","id":"pl-exit","name":"ExitPlanMode"}]"""));
        check(planning.ActivityState(askStart.AddSeconds(1_200)) == TokenActivityState.Input, "Input state: a pending plan approval must wait for the person");
        var mixed = new TokenLogParser(TokenSource.Claude);
        Feed(mixed, ClaudeUser("mx-in", "2026-10-04T09:00:00Z", "go", """{"origin":{"kind":"human"}}"""));
        Feed(mixed, ClaudeReply("mx-msg", 5, "2026-10-04T09:00:01Z", "mx-out",
                                """[{"type":"tool_use","id":"mx-ask","name":"AskUserQuestion"},{"type":"tool_use","id":"mx-bash","name":"Bash"}]"""));
        check(mixed.ActivityState(askStart.AddSeconds(60)) == TokenActivityState.Input && mixed.RunningTool?.Name == "AskUserQuestion",
              "Input state: a question pending beside another tool must name the question, not the other tool");
        (string, ToolCategory)[] categories = [("exec", ToolCategory.Command), ("js", ToolCategory.Command), ("apply_patch", ToolCategory.File),
            ("Read", ToolCategory.File), ("WebFetch", ToolCategory.Web), ("Agent", ToolCategory.Agent), ("wait_agent", ToolCategory.Agent),
            ("mcp__srv__tool", ToolCategory.Mcp), ("request_user_input_async", ToolCategory.Question), ("Monitor", ToolCategory.Other)];
        check(categories.All(pair => TokenLogParser.Category(pair.Item1) == pair.Item2), "Tool names mapped to the wrong category");

        // Claude API retries keep counts, delay and the network flag; never the error text.
        var retrying = new TokenLogParser(TokenSource.Claude);
        Feed(retrying, ClaudeUser("rt-in", "2026-10-04T09:10:00Z", "go", """{"origin":{"kind":"human"}}"""));
        Feed(retrying, J("""{"type":"system","subtype":"api_error","uuid":"rt-1","timestamp":"2026-10-04T09:10:05Z","retryAttempt":3,"maxRetries":10,"retryInMs":4000,"error":{"isNetworkDown":true,"message":"PRIVATE_ERROR","formatted":"PRIVATE_ERROR"}}"""));
        var retryAt = At("2026-10-04T09:10:09Z");
        check(retrying.Retry == new TokenRetryState(3, 10, retryAt, true, retryAt.AddSeconds(-4))
              && !$"{retrying.Retry}".Contains("PRIVATE", StringComparison.Ordinal),
              "API retry: attempt, limit, retry time or network state was lost, or message text was kept");
        Feed(retrying, ClaudeReply("rt-msg", 12, "2026-10-04T09:10:20Z", "rt-out", """[{"type":"thinking"}]"""));
        check(retrying.Retry == null, "API retry: a successful response must clear the retry state");
        Feed(retrying, J("""{"type":"system","subtype":"api_error","uuid":"rt-2","timestamp":"2026-10-04T09:10:30Z","retryAttempt":1,"maxRetries":10,"retryInMs":500,"error":{"isNetworkDown":false}}"""));
        Feed(retrying, J("""{"type":"system","subtype":"stop_hook_summary","uuid":"rt-end","timestamp":"2026-10-04T09:10:40Z"}"""));
        check(retrying.Retry == null, "API retry: turn end must clear the retry state");

        // Codex usage limit and context: newest own record wins; forked replays never count.
        var usageLimits = new TokenLogParser(TokenSource.Codex);
        Feed(usageLimits, J("""{"type":"session_meta","payload":{"id":"limit-fork","timestamp":"2026-10-04T10:00:00Z","agent_nickname":"Nick Name","source":{"subagent":{"thread_spawn":{"agent_role":"explorer","parent_thread_id":"p"}}}}}"""));
        Feed(usageLimits, J("""{"type":"compacted","timestamp":"2026-10-04T10:00:00Z","payload":{"window_number":2}}"""));
        Feed(usageLimits, Limited("2026-10-04T10:00:00Z", 90, 1_791_200_000, 200_000));
        Feed(usageLimits, Codex("task_started", "2026-10-04T10:00:00Z", """{"turn_id":"parent","started_at":"2026-10-04T09:00:00Z"}"""));
        Feed(usageLimits, Limited("2026-10-04T10:00:00.500Z", 91, 1_791_200_000, 210_000));
        Feed(usageLimits, Codex("task_complete", "2026-10-04T10:00:01Z", """{"turn_id":"parent","duration_ms":60000}"""));
        check(usageLimits.RateLimit == null && usageLimits.Context == null && usageLimits.LastTurnDuration == null,
              "Codex snapshots: a forked log's replayed parent limit, context, compaction or duration was kept");
        Feed(usageLimits, J("""{"type":"turn_context","timestamp":"2026-10-04T10:00:02Z","payload":{"model":"own-model","turn_id":"own","cwd":"/tmp/Fixture/LimitProject","collaboration_mode":{"settings":{"reasoning_effort":"xhigh"}}}}"""));
        Feed(usageLimits, Codex("task_started", "2026-10-04T10:00:02Z", """{"turn_id":"own"}"""));
        Feed(usageLimits, Limited("2026-10-04T10:00:05Z", 28.5, 1_791_300_000, 120_000));
        Feed(usageLimits, Limited("2026-10-04T10:00:04Z", 99, 1_791_300_000, 999_000));
        Feed(usageLimits, Limited("2026-10-04T10:00:06Z", 1, 1_791_300_000, 1, limit: "premium"));
        Feed(usageLimits, J("""{"type":"compacted","timestamp":"2026-10-04T10:00:07Z","payload":{"window_number":3}}"""));
        var limitAt = At("2026-10-04T10:00:05Z");
        check(usageLimits.RateLimit == new TokenRateLimit(28.5, 10_080, DateTimeOffset.FromUnixTimeSeconds(1_791_300_000), limitAt),
              "Codex usage limit: the newest own record must win over older, other-limit or replayed records");
        check(usageLimits.Context?.UsedTokens == 1 && usageLimits.Context?.WindowTokens == 258_400 && usageLimits.Context?.CompactedAt == limitAt.AddSeconds(2),
              "Codex context: the newest input count, its window or the own compaction time was lost");
        check(usageLimits.Effort == "xhigh" && usageLimits.AgentRole == "explorer" && usageLimits.Model == "own-model"
              && usageLimits.ProjectPath == "/tmp/Fixture/LimitProject" && usageLimits.Project == "LimitProject",
              "Codex metadata: effort, subagent role or the full project path was not kept");
        var corrupt = new TokenLogParser(TokenSource.Claude);
        Feed(corrupt, J("""{"type":"user","uuid":"huge-in","timestamp":"2026-10-04T10:00:00Z","origin":{"kind":"human"},"message":{"content":"go"}}"""));
        Feed(corrupt, J("""{"type":"system","subtype":"api_error","timestamp":"2026-10-04T10:00:01Z","retryAttempt":1,"retryInMs":1e25}"""));
        check(corrupt.Retry != null && corrupt.Retry?.RetryAt == null, "An out-of-range retry delay was kept");
        Feed(corrupt, J("""{"type":"system","subtype":"turn_duration","timestamp":"2026-10-04T10:00:02Z","durationMs":1e22}"""));
        check(corrupt.LastTurnDuration == null, "An out-of-range turn duration was kept and could trap integer formatting");
        var twoWindows = new TokenLogParser(TokenSource.Codex);
        Feed(twoWindows, Codex("task_started", "2026-10-04T10:00:00Z", """{"turn_id":"own"}"""));
        Feed(twoWindows, Codex("token_count", "2026-10-04T10:00:01Z", """{"rate_limits":{"limit_id":"codex","primary":{"used_percent":20,"window_minutes":300,"resets_at":1791100000},"secondary":{"used_percent":97,"window_minutes":10080,"resets_at":1791500000}}}"""));
        check(twoWindows.RateLimit?.UsedPercent == 97 && twoWindows.RateLimit?.WindowMinutes == 10_080,
              "Codex usage limit: a near-full weekly secondary window was hidden behind the 5-hour primary");
        var review = new TokenLogParser(TokenSource.Codex);
        Feed(review, J("""{"type":"session_meta","payload":{"id":"review","source":{"subagent":{"other":"guardian"}}}}"""));
        Feed(review, J("""{"type":"turn_context","payload":{"model":"m","effort":"low"}}"""));
        check(review.AgentRole == "guardian" && review.Effort == "low",
              "Codex metadata: an automatic review thread or a plain effort field was not labelled");
        var compactedClaude = new TokenLogParser(TokenSource.Claude);
        Feed(compactedClaude, Assistant("cc-a", 10, "2026-10-04T11:00:00Z", "cc-a"));
        Feed(compactedClaude, J("""{"type":"system","subtype":"compact_boundary","uuid":"cc-b","timestamp":"2026-10-04T11:01:00Z","compactMetadata":{"trigger":"auto","preTokens":900000,"durationMs":90000}}"""));
        check(compactedClaude.Context?.CompactedAt == At("2026-10-04T11:01:00Z") && compactedClaude.Context?.UsedTokens == 150_000,
              "Claude context: the compaction boundary time was not recorded");

        // Windows (DESIGN WP1): a C:\ working directory names its project on every OS.
        var windowsCwd = new TokenLogParser(TokenSource.Claude);
        Feed(windowsCwd, J("""{"type":"user","uuid":"w","timestamp":"2026-10-04T04:00:00Z","cwd":"C:\\Users\\me\\proj","message":{"content":"go"}}"""));
        check(windowsCwd.Project == "proj" && windowsCwd.ProjectPath == @"C:\Users\me\proj",
              @"Windows: a C:\ working directory did not name its project");

        var root = Path.Combine(Path.GetTempPath(), $"TokenCat-check-{Guid.NewGuid()}");
        try
        {
            var folder = Path.Combine(root, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(folder);
            var a = Path.Combine(folder, "a.jsonl");
            var b = Path.Combine(folder, "b.jsonl");
            var ending = Line(Codex("task_complete", "2026-10-04T04:00:02Z", """{"turn_id":"a","duration_ms":2000}"""));
            File.WriteAllBytes(a, [.. Lines(J("""{"type":"session_meta","payload":{"id":"session-a","cwd":"/tmp/ProjectA"}}"""),
                J("""{"type":"turn_context","payload":{"model":"model-a"}}"""),
                Codex("task_started", "2026-10-04T04:00:00Z", """{"turn_id":"a"}"""),
                Usage(100, 100, "2026-10-04T04:00:01Z")), .. ending[..(ending.Length / 2)]]);
            File.WriteAllBytes(b, Lines(J("""{"type":"session_meta","payload":{"id":"session-b","cwd":"/tmp/ProjectB"}}"""),
                J("""{"type":"turn_context","payload":{"model":"model-b"}}"""),
                Codex("task_started", "2026-10-04T04:00:00Z", """{"turn_id":"b"}"""),
                Usage(20, 20, "2026-10-04T04:00:01Z")));
            var now = At("2026-10-04T04:00:03Z");
            var tracker = new TokenTracker(root, () => now, discoveryIntervalSeconds: 0);
            var first = tracker.Sample();
            check(first.Count == 2 && first.All(r => r.Active && r.LastOutputTokens == null && r.LastTurnDurationSeconds == null),
                  "Partial JSONL or simultaneous sessions were combined");
            check(first.Select(r => r.Id).Distinct().Count() == 2 && SetIs(first.Select(r => r.Model), "model-a", "model-b"),
                  "Concurrent sessions lost their separate stable IDs or models");
            check(SetIs(first.Select(r => r.Project), "ProjectA", "ProjectB"), "Session project metadata was not retained");
            File.AppendAllBytes(a, ending[(ending.Length / 2)..]);
            var second = tracker.Sample();
            var secondA = second.FirstOrDefault(r => r.SessionID == "session-a");
            check(second.FirstOrDefault()?.SessionID == "session-b" && second.FirstOrDefault()?.Active == true
                  && second.FirstOrDefault()?.LastOutputTokens == null
                  && secondA?.LastTurnDurationSeconds == 2 && secondA?.LastOutputTokens == 100,
                  "Active session inherited another session's completion, or active-first sorting failed");
            check(first.Select(r => r.Id).ToHashSet().SetEquals(second.Select(r => r.Id)), "Incremental updates changed session identity");
            File.AppendAllBytes(b, Line(Codex("task_complete", "2026-10-04T04:00:03Z", """{"turn_id":"b","duration_ms":2000}""")));
            var third = tracker.Sample()[0];
            check(third.LastTurnDurationSeconds == 2 && third.LastOutputTokens == 20, "Incremental completion selected incorrect simultaneous session");
            var repeatSample = tracker.Sample()[0];
            check(repeatSample.LastOutputTokens == 20, "Repeated file sample duplicated output");
            File.WriteAllBytes(b, "{}\n"u8.ToArray());
            var truncated = tracker.Sample()[0];
            check(truncated.LastTurnDurationSeconds == 2 && truncated.LastOutputTokens == 100, "Truncated file kept stale usage state");

            File.AppendAllBytes(a, Lines(J("""{"type":"turn_context","payload":{"model":"model-a-new"}}"""),
                Codex("task_started", "2026-10-04T04:00:03Z", """{"turn_id":"a-next"}""")));
            var switched = tracker.Sample().FirstOrDefault(r => r.SessionID == "session-a");
            check(switched?.Model == "model-a-new" && switched?.LastOutputTokens == 100,
                  "Changing the current model reassigned an earlier measurement to the new model");
            check(new TokenTracker(Path.Combine(root, "empty"), () => now).Sample().Count == 0, "An empty log directory fabricated provider rows");

            var claudeProject = Path.Combine(root, ".claude", "projects", "fixture-project");
            var subagentFolder = Path.Combine(claudeProject, "shared", "subagents");
            Directory.CreateDirectory(subagentFolder);
            foreach (var isAgent in (bool[])[false, true])
            {
                var flag = isAgent ? "true" : "false";
                var input = J(Fill("""{"type":"user","uuid":"input-<flag>","timestamp":"2026-10-04T04:00:00Z","sessionId":"shared-session","cwd":"/tmp/ClaudeProject","isSidechain":<flag>,"message":{"content":[{"type":"text"}]}}""", ("<flag>", flag)));
                if (isAgent) input["agentId"] = "worker-one";
                var output = Assistant($"out-{flag}", isAgent ? 20 : 60, "2026-10-04T04:00:01Z", $"uuid-{flag}");
                output["sessionId"] = "shared-session";
                output["isSidechain"] = isAgent;
                output["message"]!["model"] = isAgent ? "claude-worker" : "claude-main";
                if (isAgent) output["agentId"] = "worker-one";
                var duration = J(Fill("""{"type":"system","subtype":"turn_duration","parentUuid":"uuid-<flag>","timestamp":"2026-10-04T04:00:02Z","durationMs":2000,"isSidechain":<flag>}""", ("<flag>", flag)));
                var foreign = Assistant("foreign", 999, "2026-10-04T04:00:03Z", "foreign");
                foreign["isSidechain"] = true;
                File.WriteAllBytes(isAgent ? Path.Combine(subagentFolder, "agent-worker.jsonl") : Path.Combine(claudeProject, "shared.jsonl"),
                    isAgent ? Lines(input, output, duration) : Lines(input, output, duration, foreign));
            }
            File.WriteAllBytes(Path.Combine(subagentFolder, "agent-worker.meta.json"),
                Line(J("""{"agentType":"workflow-subagent","description":"PRIVATE_TASK","worktreePath":"/tmp/PRIVATE_PATH","spawnDepth":1}""")));
            var claudeSessions = tracker.Sample().Where(r => r.Source == TokenSource.Claude).ToList();
            var encodedSessions = Encoding.UTF8.GetString(Json.Serialize(claudeSessions));
            check(claudeSessions.FirstOrDefault(r => r.IsSubagent)?.AgentRole == "workflow-subagent"
                  && claudeSessions.FirstOrDefault(r => !r.IsSubagent)?.AgentRole == null && !encodedSessions.Contains("PRIVATE", StringComparison.Ordinal),
                  "Claude subagent sidecar: agentType was not kept, or another sidecar key leaked");
            check(claudeSessions.All(r => r.ProjectPath == "/tmp/ClaudeProject" && r.Project == "ClaudeProject"),
                  "Claude project path was not kept alongside the project name");
            check(claudeSessions.Count == 2 && claudeSessions.Select(r => r.Id).Distinct().Count() == 2,
                  "Claude main and subagent with the same sessionId were merged or omitted");
            check(claudeSessions.FirstOrDefault(r => r.IsSubagent)?.LastOutputTokens == 20
                  && claudeSessions.FirstOrDefault(r => !r.IsSubagent)?.LastOutputTokens == 60
                  && claudeSessions.All(r => r.LastTurnDurationSeconds == 2),
                  "Claude nested sidechain usage leaked into the main log, or was ignored in the child log");
            check(SetIs(claudeSessions.Select(r => r.Model), "claude-main", "claude-worker"),
                  "Claude main/subagent model identity was overwritten by sidechain records");
            var workflowFolder = Path.Combine(subagentFolder, "workflows", "fixture-workflow");
            Directory.CreateDirectory(workflowFolder);
            var workerBody = File.ReadAllText(Path.Combine(subagentFolder, "agent-worker.jsonl"))
                .Replace("worker-one", "worker-two", StringComparison.Ordinal).Replace("claude-worker", "claude-workflow", StringComparison.Ordinal);
            File.WriteAllText(Path.Combine(workflowFolder, "agent-workflow.jsonl"), workerBody);
            var workflowSessions = tracker.Sample().Where(r => r.Source == TokenSource.Claude).ToList();
            check(workflowSessions.Count == 3 && workflowSessions.Any(r =>
                      r.IsSubagent && r.AgentID == "worker-two" && r.Model == "claude-workflow" && r.LastOutputTokens == 20),
                  "Claude workflow-nested subagent was not discovered or lost its sidechain identity");

            // Begin reading within a large line: suffixes and unseen turn starts cannot produce rates.
            File.WriteAllBytes(a, [.. Spaces(2_048), .. Lines(Usage(800, 100, "2026-10-04T04:00:04Z"),
                Codex("task_complete", "2026-10-04T04:00:05Z", """{"turn_id":"unseen","duration_ms":1000}"""))]);
            var bounded = new TokenTracker(root, () => now, initialTailBytes: 256);
            check(bounded.Sample().Where(r => r.Source == TokenSource.Codex).All(r => r.LastOutputTokens == null && r.LastTurnDurationSeconds == null),
                  "Initial bounded tail attributed an unseen turn's output or duration");

            // A bounded tail can still recover identity/project from the metadata-only header.
            var headerHome = Path.Combine(root, "header");
            var headerFolder = Path.Combine(headerHome, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(headerFolder);
            File.WriteAllBytes(Path.Combine(headerFolder, "header.jsonl"), [
                .. Lines(J("""{"type":"session_meta","payload":{"id":"header-session","cwd":"/tmp/HeaderProject"}}"""),
                    J("""{"type":"turn_context","payload":{"model":"stale-header-model"}}""")),
                .. Spaces(2_048),
                .. Lines(J("""{"type":"turn_context","payload":{"model":"fresh-tail-model"}}"""),
                    Codex("task_started", "2026-10-04T04:00:01Z", """{"turn_id":"header-turn"}"""))]);
            var headerReading = new TokenTracker(headerHome, () => now, initialTailBytes: 512).Sample().FirstOrDefault();
            check(headerReading?.SessionID == "header-session" && headerReading?.Project == "HeaderProject",
                  "Bounded tail lost session/project metadata from the initial header");
            check(headerReading?.Model == "fresh-tail-model" && headerReading?.LastOutputTokens == null,
                  "Metadata header replayed an old model or lifecycle/usage");

            var longHome = Path.Combine(root, "long-open-turn");
            var longFolder = Path.Combine(longHome, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(longFolder);
            var longFile = Path.Combine(longFolder, "long.jsonl");
            File.WriteAllBytes(longFile, [
                .. Lines(J("""{"type":"session_meta","payload":{"id":"long-session","cwd":"/tmp/LongProject","timestamp":"2026-10-04T04:00:00Z"}}"""),
                    Codex("task_started", "2026-10-04T04:00:01Z", """{"turn_id":"long-turn"}"""),
                    J("""{"type":"turn_context","timestamp":"2026-10-04T04:00:01Z","payload":{"model":"long-model","turn_id":"long-turn","cwd":"/tmp/CurrentProject"}}""")),
                .. Spaces(4_096),
                .. Line(Usage(50, 50, "2026-10-04T04:00:03Z"))]);
            var longNow = At("2026-10-04T04:00:08Z");
            var longTracker = new TokenTracker(longHome, () => longNow, initialTailBytes: 512);
            var openLong = longTracker.Sample().FirstOrDefault();
            check(openLong?.Model == "long-model" && openLong?.Project == "CurrentProject" && openLong?.Active == true && openLong?.LastOutputTokens == null,
                  "Starting mid-turn lost current model/activity or fabricated a partial turn output");
            check(openLong?.CurrentTurnStartedAt == At("2026-10-04T04:00:01Z") && openLong?.CurrentTurnOutputTokens == null
                  && openLong?.ActivityState == TokenActivityState.Working && openLong?.LastOutputDelta == 50 && openLong?.SampledAt == longNow,
                  "Restored live metadata must expose elapsed time and observed delta without inventing a whole-turn output count");
            // The writer keeps this log open across the next fixtures and flushes each append (rule 8).
            using var longAppend = new FileStream(longFile, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            void Append(FileStream stream, params JsonNode[] values)
            {
                stream.Write(Lines(values));
                stream.Flush();
            }
            Append(longAppend, Codex("task_complete", "2026-10-04T04:00:04Z", """{"turn_id":"long-turn","duration_ms":3000}"""));
            var closedLong = longTracker.Sample().FirstOrDefault();
            check(closedLong?.Active == false && closedLong?.LastOutputTokens == null && closedLong?.LastTurnDurationSeconds == 3,
                  "A metadata-only open turn stayed active, reported a partial output, or lost its own reported duration");
            check(closedLong?.ActivityState == TokenActivityState.Complete && closedLong?.CurrentTurnStartedAt == null
                  && closedLong?.CurrentTurnOutputTokens == null,
                  "A restored live turn's completion must close state without a partial-rate accumulator");
            // A Codex turn whose start is outside the tail still reports its recorded total.
            foreach (var (name, usageInTail) in new[] { ("usage-in-tail", true), ("usage-before-tail", false) })
            {
                var usageHome = Path.Combine(root, name);
                var usageFolder = Path.Combine(usageHome, ".codex", "sessions", "2026", "10", "04");
                Directory.CreateDirectory(usageFolder);
                var record = Line(UsageRecord("restored-resp", "restored-turn", 300, 5_300, "2026-10-04T04:00:06Z"));
                File.WriteAllBytes(Path.Combine(usageFolder, $"{name}.jsonl"), [
                    .. Lines(J(Fill("""{"type":"session_meta","payload":{"id":"<name>","timestamp":"2026-10-04T04:00:00Z"}}""", ("<name>", name))),
                        Codex("task_started", "2026-10-04T04:00:01Z", """{"turn_id":"restored-turn"}"""),
                        J("""{"type":"turn_context","timestamp":"2026-10-04T04:00:01Z","payload":{"model":"usage-model","turn_id":"restored-turn"}}""")),
                    .. usageInTail ? [] : record,
                    .. Spaces(4_096),
                    .. usageInTail ? record : []]);
                var restored = new TokenTracker(usageHome, () => longNow, initialTailBytes: 512).Sample().FirstOrDefault();
                check(restored?.Active == true && restored?.CurrentTurnOutputTokens == 5_300
                      && restored?.CurrentTurnStartedAt == At("2026-10-04T04:00:01Z"),
                      $"Codex usage record ({name}): a turn started outside the tail lost its recorded cumulative output");
            }

            // A long Claude turn whose human input precedes the tail is read from that input.
            var claudeLongHome = Path.Combine(root, "claude-long-turn");
            var claudeLongFolder = Path.Combine(claudeLongHome, ".claude", "projects", "long");
            Directory.CreateDirectory(claudeLongFolder);
            File.WriteAllBytes(Path.Combine(claudeLongFolder, "open.jsonl"), [
                .. Lines(J("""{"type":"user","uuid":"long-human","timestamp":"2026-10-04T04:00:00Z","sessionId":"long-claude","message":{"content":[{"type":"text"}]}}"""),
                    Assistant("long-1", 400, "2026-10-04T04:00:01Z", "long-a")),
                .. Spaces(4_096),
                .. Line(Assistant("long-2", 50, "2026-10-04T04:00:07Z", "long-b"))]);
            File.WriteAllBytes(Path.Combine(claudeLongFolder, "closed.jsonl"), [
                .. Lines(J("""{"type":"user","uuid":"closed-human","timestamp":"2026-10-04T03:59:00Z","sessionId":"closed-claude","message":{"content":[{"type":"text"}]}}"""),
                    Assistant("closed-1", 100, "2026-10-04T03:59:01Z", "closed-a"),
                    J("""{"type":"system","subtype":"stop_hook_summary","parentUuid":"closed-a","timestamp":"2026-10-04T03:59:02Z"}""")),
                .. Spaces(4_096)]);
            var claudeLong = new TokenTracker(claudeLongHome, () => longNow, initialTailBytes: 512).Sample();
            var openClaude = claudeLong.FirstOrDefault(r => r.SessionID == "long-claude");
            check(openClaude?.Active == true && openClaude?.CurrentTurnOutputTokens == 450 && openClaude?.CurrentTurnStartedAt == At("2026-10-04T04:00:00Z"),
                  "Claude long turn: output before the tail was reported unknown instead of read from the human input");
            check(!claudeLong.Any(r => r.SessionID == "closed-claude"), "Claude long turn: a closed turn before the tail was replayed");

            var abortedHome = Path.Combine(root, "restored-interruption");
            var abortedFolder = Path.Combine(abortedHome, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(abortedFolder);
            File.WriteAllBytes(Path.Combine(abortedFolder, "aborted.jsonl"), [
                .. Lines(J("""{"type":"session_meta","payload":{"id":"aborted-session","timestamp":"2026-10-04T04:00:00Z"}}"""),
                    Codex("task_started", "2026-10-04T04:00:00Z", """{"turn_id":"aborted-turn"}"""),
                    J("""{"type":"turn_context","timestamp":"2026-10-04T04:00:00Z","payload":{"model":"aborted-model","turn_id":"aborted-turn"}}"""),
                    Codex("turn_aborted", "2026-10-04T04:00:02Z", """{"turn_id":"aborted-turn"}""")),
                .. Spaces(4_096)]);
            var restoredAbort = new TokenTracker(abortedHome, () => longNow, initialTailBytes: 512).Sample().FirstOrDefault();
            check(restoredAbort?.ActivityState == TokenActivityState.Interrupted && restoredAbort?.Active == false
                  && restoredAbort?.CurrentTurnStartedAt == null && restoredAbort?.CurrentTurnOutputTokens == null,
                  "A metadata-restored aborted Codex turn was presented as completed");
            Append(longAppend, Codex("task_started", "2026-10-04T04:00:05Z", """{"turn_id":"complete-turn"}"""),
                Usage(70, 20, "2026-10-04T04:00:06Z"),
                Codex("task_complete", "2026-10-04T04:00:07Z", """{"turn_id":"complete-turn","duration_ms":2000}"""));
            longAppend.Dispose();
            check(longTracker.Sample().FirstOrDefault() is { LastOutputTokens: 20, LastTurnDurationSeconds: 2 },
                  "The next fully observed turn did not recover its output and duration");

            // Forked logs can put the inherited opener outside the initial tail.
            var inheritedHome = Path.Combine(root, "long-inherited-turn");
            var inheritedFolder = Path.Combine(inheritedHome, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(inheritedFolder);
            var inheritedFile = Path.Combine(inheritedFolder, "child.jsonl");
            File.WriteAllBytes(inheritedFile, [
                .. Lines(J("""{"type":"session_meta","payload":{"id":"child-session","cwd":"/tmp/ChildProject","timestamp":"2026-10-04T04:00:10Z","source":{"subagent":{"agent_path":"worker"}}}}"""),
                    Codex("task_started", "2026-10-04T04:00:11Z", """{"turn_id":"parent-turn","started_at":"2026-10-04T04:00:00Z"}"""),
                    J("""{"type":"turn_context","timestamp":"2026-10-04T04:00:11Z","payload":{"model":"parent-model","turn_id":"parent-turn","cwd":"/tmp/ParentProject"}}""")),
                .. Spaces(4_096),
                .. Lines(Usage(100, 100, "2026-10-04T04:00:12Z"),
                    Codex("task_complete", "2026-10-04T04:00:13Z", """{"turn_id":"parent-turn","duration_ms":3000}"""))]);
            var inheritedNow = At("2026-10-04T04:00:18Z");
            var inheritedTracker = new TokenTracker(inheritedHome, () => inheritedNow, initialTailBytes: 512);
            check(inheritedTracker.Sample().Count == 0,
                  "Bounded metadata recovery restored inherited parent model, activity, or output in the child");
            File.AppendAllBytes(inheritedFile, Lines(
                J("""{"type":"turn_context","timestamp":"2026-10-04T04:00:14Z","payload":{"model":"child-model","turn_id":"child-turn","cwd":"/tmp/ChildProject"}}"""),
                Codex("task_started", "2026-10-04T04:00:14Z", """{"turn_id":"child-turn"}"""),
                Usage(120, 20, "2026-10-04T04:00:14.500Z"),
                Codex("task_complete", "2026-10-04T04:00:15Z", """{"turn_id":"child-turn","duration_ms":1000}""")));
            var recoveredChild = inheritedTracker.Sample().FirstOrDefault();
            check(recoveredChild?.Model == "child-model" && recoveredChild?.Project == "ChildProject"
                  && recoveredChild?.LastTurnDurationSeconds == 1 && recoveredChild?.LastOutputTokens == 20,
                  "A child turn after bounded inherited history failed to restore its own model and measurement");
            check(recoveredChild?.LastOutputDelta == 20 && recoveredChild?.ActivityState == TokenActivityState.Complete,
                  "Inherited parent output delta or activity leaked into a child live row");

            var newSessionHome = Path.Combine(root, "new-session-discovery");
            var newSessionFolder = Path.Combine(newSessionHome, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(newSessionFolder);
            var discoveryNow = longNow;
            var newSessionTracker = new TokenTracker(newSessionHome, () => discoveryNow);
            check(newSessionTracker.Sample().Count == 0, "An empty home fabricated live placeholder sessions");
            File.WriteAllBytes(Path.Combine(newSessionFolder, "new.jsonl"), Line(Codex("task_started", "2026-10-04T04:00:10Z", """{"turn_id":"new-session"}""")));
            discoveryNow = longNow.AddSeconds(5);
            var newlyDiscovered = newSessionTracker.Sample().FirstOrDefault();
            check(newlyDiscovered?.ActivityState == TokenActivityState.Working && newlyDiscovered?.CurrentTurnOutputTokens == 0
                  && newlyDiscovered?.SampledAt == discoveryNow,
                  "Default discovery must collect a new observed session within five seconds");

            // Appends wake sampling through file-system events, and Stop() ends callbacks.
            var watchRoot = Path.Combine(root, "watch", ".codex", "sessions");
            Directory.CreateDirectory(watchRoot);
            using var woke = new SemaphoreSlim(0);
            var watchedFile = Path.Combine(watchRoot, "live.jsonl");
            using var watcher = new LogWatcher(paths =>
            {
                if (paths.Any(path => Path.GetFileName(path) == "live.jsonl")) woke.Release();
            });
            check(watcher.Start([watchRoot, Path.Combine(root, "missing")]), "Log watcher could not watch an existing log directory");
            var written = Stopwatch.StartNew();
            File.WriteAllBytes(watchedFile, Line(Codex("task_started", "2026-10-04T04:00:00Z", """{"turn_id":"watched"}""")));
            var wokeInTime = woke.Wait(TimeSpan.FromSeconds(3));
            check(wokeInTime && written.Elapsed.TotalSeconds < 1.5, "Log watcher did not report a log write within 1.5 s");
            watcher.Stop();
            while (woke.Wait(TimeSpan.FromSeconds(0.3))) { }
            File.WriteAllBytes(watchedFile, Line(Usage(10, 10, "2026-10-04T04:00:01Z")));
            check(!woke.Wait(TimeSpan.FromSeconds(0.6)), "Log watcher delivered events after stop()");
            check(!new LogWatcher(_ => { }).Start([Path.Combine(root, "missing")]), "Log watcher claimed to watch a missing directory");

            // A forked Codex log replays the parent's session_meta and open turn after its own.
            var forkHome = Path.Combine(root, "fork");
            var forkFolder = Path.Combine(forkHome, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(forkFolder);
            const string childID = "0000c41d-0000-7000-8000-00000000c41d", rootID = "0000a007-0000-7000-8000-00000000a007";
            File.WriteAllBytes(Path.Combine(forkFolder, $"rollout-2026-10-04T06-54-35-{childID}.jsonl"), Lines(
                J(Fill("""{"type":"session_meta","timestamp":"2026-10-04T06:54:35Z","payload":{"id":"<childID>","session_id":"<rootID>","timestamp":"2026-10-04T06:54:35Z","cwd":"/tmp/ForkProject","agent_path":"/root/worker","source":{"subagent":{"thread_spawn":{"parent_thread_id":"<rootID>"}}}}}""", ("<childID>", childID), ("<rootID>", rootID))),
                J(Fill("""{"type":"session_meta","timestamp":"2026-10-04T06:54:35Z","payload":{"id":"<rootID>","session_id":"<rootID>","timestamp":"2026-10-04T03:43:12Z","cwd":"/tmp/ParentProject","source":"vscode"}}""", ("<rootID>", rootID))),
                Codex("task_started", "2026-10-04T06:54:35Z", """{"turn_id":"parent-open","started_at":1791090000}"""),
                Codex("task_started", "2026-10-04T06:54:36Z", """{"turn_id":"child-own"}"""),
                UsageRecord("child-resp", "child-own", 161, 161, "2026-10-04T06:54:41Z")));
            var forkNow = At("2026-10-04T06:54:45Z");
            var forkReading = new TokenTracker(forkHome, () => forkNow).Sample().FirstOrDefault();
            check(forkReading?.SessionID == childID && forkReading?.ParentSessionID == rootID && forkReading?.IsSubagent == true
                  && forkReading?.Project == "ForkProject",
                  "Forked Codex log: the replayed parent session_meta replaced the child's identity");
            check(forkReading?.CurrentTurnOutputTokens == 161 && forkReading?.CurrentTurnStartedAt == At("2026-10-04T06:54:36Z"),
                  "Forked Codex log: the inherited parent turn was treated as the child's own");

            // A quiet main session in a turn survives a burst of newer logs.
            var retainHome = Path.Combine(root, "retain");
            var retainFolder = Path.Combine(retainHome, ".claude", "projects", "busy");
            Directory.CreateDirectory(retainFolder);
            var quiet = Path.Combine(retainFolder, "quiet.jsonl");
            File.WriteAllBytes(quiet, Lines(ClaudeUser("q-in", "2026-10-04T04:00:00Z", "long job", """{"sessionId":"quiet","origin":{"kind":"human"}}"""),
                ClaudeReply("q-msg", 10, "2026-10-04T04:00:01Z", "q-out", """[{"type":"tool_use","id":"q-tool"}]""")));
            File.SetLastWriteTimeUtc(quiet, now.AddSeconds(-600).UtcDateTime);
            var retainTracker = new TokenTracker(retainHome, () => now, discoveryIntervalSeconds: 0);
            check(retainTracker.Sample().Any(r => r.SessionID == "quiet"), "Retention fixture: quiet session not discovered");
            for (var index = 0; index < 33; index++)
                File.WriteAllBytes(Path.Combine(retainFolder, $"busy-{index}.jsonl"), Lines(
                    ClaudeUser($"b{index}", "2026-10-04T04:00:02Z", "x", Fill("""{"sessionId":"busy-<index>"}""", ("<index>", index))),
                    J("""{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-04T04:00:03Z"}""")));
            check(retainTracker.Sample().Any(r => r.SessionID == "quiet" && r.CurrentTurnOutputTokens == 10),
                  "Discovery evicted a quiet session that is still in a turn");

            // A tool result over the 1 MB line limit still completes its call.
            var bigHome = Path.Combine(root, "oversized");
            var bigFolder = Path.Combine(bigHome, ".claude", "projects", "big");
            Directory.CreateDirectory(bigFolder);
            File.WriteAllBytes(Path.Combine(bigFolder, "big.jsonl"), [
                .. Lines(ClaudeUser("g-in", "2026-10-04T04:00:00Z", "read", """{"origin":{"kind":"human"}}"""),
                    ClaudeReply("g-msg", 10, "2026-10-04T04:00:01Z", "g-out", """[{"type":"tool_use","id":"g-tool"}]""")),
                .. "{\"parentUuid\":\"g-out\",\"isSidechain\":false,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"g-tool\",\"type\":\"tool_result\",\"content\":\""u8.ToArray(),
                .. Enumerable.Repeat((byte)120, 1_200_000),
                .. "\"}]},\"uuid\":\"g-result\",\"timestamp\":\"2026-10-04T04:00:02Z\"}\n"u8.ToArray()]);
            var bigReading = new TokenTracker(bigHome, () => now, initialTailBytes: 4_194_304).Sample().FirstOrDefault();
            check(bigReading?.ActivityState == TokenActivityState.Working, "An oversized tool result left its call running");

            // Readings carry the new fields: input state, tool category, usage limit, context and duration.
            var fieldsHome = Path.Combine(root, "fields");
            var fieldsClaude = Path.Combine(fieldsHome, ".claude", "projects", "fields");
            var fieldsCodex = Path.Combine(fieldsHome, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(fieldsClaude);
            Directory.CreateDirectory(fieldsCodex);
            File.WriteAllBytes(Path.Combine(fieldsClaude, "ask.jsonl"), Lines(
                ClaudeUser("f-in", "2026-10-04T04:00:00Z", "ask", """{"sessionId":"asking","origin":{"kind":"human"}}"""),
                ClaudeReply("f-msg", 9, "2026-10-04T04:00:01Z", "f-out", """[{"type":"tool_use","id":"f-q","name":"AskUserQuestion"}]""")));
            File.WriteAllBytes(Path.Combine(fieldsCodex, "fields.jsonl"), Lines(
                J("""{"type":"session_meta","payload":{"id":"fields-codex","cwd":"/tmp/Fixture/FieldsProject","timestamp":"2026-10-04T03:59:00Z"}}"""),
                J("""{"type":"turn_context","payload":{"model":"fields-model","effort":"high"}}"""),
                Codex("task_started", "2026-10-04T03:59:00Z", """{"turn_id":"f-1"}"""),
                Limited("2026-10-04T03:59:01Z", 42, 1_791_400_000, 64_000),
                Codex("task_complete", "2026-10-04T03:59:02Z", """{"turn_id":"f-1","duration_ms":2500}"""),
                Codex("task_started", "2026-10-04T04:00:00Z", """{"turn_id":"f-2"}"""),
                J("""{"type":"response_item","timestamp":"2026-10-04T04:00:01Z","payload":{"type":"custom_tool_call","call_id":"f-exec","name":"exec","input":"PRIVATE_CMD"}}""")));
            var fieldsNow = At("2026-10-04T06:00:00Z");
            var fields = new TokenTracker(fieldsHome, () => fieldsNow).Sample();
            var askReading = fields.FirstOrDefault(r => r.Source == TokenSource.Claude);
            check(askReading?.ActivityState == TokenActivityState.Input && askReading?.Active == true
                  && askReading?.ToolCategory == ToolCategory.Question && askReading?.ToolName == "AskUserQuestion",
                  "Tracker: a two-hour-old pending question was not reported as live input");
            var codexFields = fields.FirstOrDefault(r => r.Source == TokenSource.Codex);
            check(codexFields?.ToolCategory == ToolCategory.Command && codexFields?.ToolName == "exec"
                  && codexFields?.RateLimit?.UsedPercent == 42 && codexFields?.Context?.UsedTokens == 64_000
                  && codexFields?.Context?.WindowTokens == 258_400 && codexFields?.Effort == "high"
                  && codexFields?.LastTurnDurationSeconds == 2.5 && codexFields?.LastOutputTokens == 10
                  && codexFields?.ProjectPath == "/tmp/Fixture/FieldsProject" && codexFields?.Retry == null,
                  "Tracker: Codex tool category, usage limit, context, effort, duration or project path was not exported");
            var encodedFields = Encoding.UTF8.GetString(Json.Serialize(fields));
            check(!encodedFields.Contains("PRIVATE", StringComparison.Ordinal) && !encodedFields.Contains("turnAverage", StringComparison.Ordinal)
                  && !encodedFields.Contains("quality", StringComparison.Ordinal),
                  "Tracker export: tool input, account balance or a log-derived rate field leaked");

            // Resuming an old Codex conversation updates its file, not its date-directory name.
            var resumedHome = Path.Combine(root, "resumed");
            var currentDay = Path.Combine(resumedHome, ".codex", "sessions", "2026", "10", "04");
            var originalDay = Path.Combine(resumedHome, ".codex", "sessions", "2026", "09", "01");
            Directory.CreateDirectory(currentDay);
            Directory.CreateDirectory(originalDay);
            var olderMeasurement = Lines(Codex("task_started", "2026-10-04T03:00:00Z", """{"turn_id":"today"}"""),
                Usage(5, 5, "2026-10-04T03:00:01Z"),
                Codex("task_complete", "2026-10-04T03:00:02Z", """{"turn_id":"today","duration_ms":2000}"""));
            for (var index = 0; index < 32; index++)
            {
                var path = Path.Combine(currentDay, $"today-{index}.jsonl");
                File.WriteAllBytes(path, olderMeasurement);
                File.SetLastWriteTimeUtc(path, now.AddSeconds(-60).UtcDateTime);
            }
            var resumedFile = Path.Combine(originalDay, "resumed.jsonl");
            File.WriteAllBytes(resumedFile, Lines(Codex("task_started", "2026-10-04T04:00:00Z", """{"turn_id":"resumed"}"""),
                Usage(100, 100, "2026-10-04T04:00:01Z"),
                Codex("task_complete", "2026-10-04T04:00:02Z", """{"turn_id":"resumed","duration_ms":2000}""")));
            File.SetLastWriteTimeUtc(resumedFile, now.UtcDateTime);
            var resumedReading = new TokenTracker(resumedHome, () => now).Sample()[0];
            check(resumedReading.LastTurnDurationSeconds == 2 && resumedReading.LastOutputTokens == 100,
                  "Codex discovery omitted a resumed old-date file newer than 32 current-day files");

            // A cold start also opens subagent logs past the newest 32 that changed within the hour, up to 64.
            var burstFolder = Path.Combine(root, "burst", ".claude", "projects", "p", "s", "subagents");
            Directory.CreateDirectory(burstFolder);
            for (var index = 0; index < 36; index++)
            {
                var record = Assistant($"burst-{index}", 5, "2026-10-04T04:00:01Z", $"burst-{index}");
                record["agentId"] = $"burst-{index}";
                record["isSidechain"] = true;
                var path = Path.Combine(burstFolder, $"agent-burst-{index}.jsonl");
                File.WriteAllBytes(path, Line(record));
                File.SetLastWriteTimeUtc(path, now.AddSeconds(-(index < 32 ? 60 : index < 35 ? 1_800 : 7_200)).UtcDateTime);
            }
            check(new TokenTracker(Path.Combine(root, "burst"), () => now).Sample().Count == 35,
                  "Cold discovery dropped subagent logs from the last hour past the newest 32, or kept older ones");

            // Windows (DESIGN WP1): watcher hints use backslashes there; only agent-* logs under subagents\ are tracked.
            var hintHome = Path.Combine(root, "hints");
            var hintFolder = Path.Combine(hintHome, ".claude", "projects", "p");
            Directory.CreateDirectory(hintFolder);
            var hintTracker = new TokenTracker(hintHome, () => now, discoveryIntervalSeconds: 3_600);
            hintTracker.Sample();
            File.WriteAllBytes(Path.Combine(hintFolder, "late.jsonl"), Line(ClaudeUser("h", "2026-10-04T04:00:00Z", "go", """{"sessionId":"late"}""")));
            hintTracker.NoteChanged([@"C:\Users\me\.claude\projects\p\s\subagents\journal.jsonl", @"C:\Users\me\.claude\projects\p\notes.txt"]);
            var ignoredHint = hintTracker.Sample().Count == 0;
            hintTracker.NoteChanged([@"C:\Users\me\.claude\projects\p\s\subagents\agent-x.jsonl"]);
            check(ignoredHint && hintTracker.Sample().Any(r => r.SessionID == "late"),
                  @"Windows: a subagents\ side file triggered discovery, or an agent-* log did not");

            // Windows (DESIGN WP1): CRLF line ends, read forward and scanned backward for a Claude turn start.
            var crlfHome = Path.Combine(root, "crlf");
            var crlfCodex = Path.Combine(crlfHome, ".codex", "sessions", "2026", "10", "04");
            var crlfClaude = Path.Combine(crlfHome, ".claude", "projects", "crlf");
            Directory.CreateDirectory(crlfCodex);
            Directory.CreateDirectory(crlfClaude);
            byte[] Crlf(byte[] lines) => Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(lines).Replace("\n", "\r\n", StringComparison.Ordinal));
            File.WriteAllBytes(Path.Combine(crlfCodex, "crlf.jsonl"), Crlf(Lines(
                J("""{"type":"session_meta","payload":{"id":"crlf-codex","cwd":"C:\\Users\\me\\CrlfProject"}}"""),
                Codex("task_started", "2026-10-04T04:00:00Z", """{"turn_id":"crlf"}"""),
                Usage(100, 100, "2026-10-04T04:00:01Z"),
                Codex("task_complete", "2026-10-04T04:00:02Z", """{"turn_id":"crlf","duration_ms":2000}"""))));
            File.WriteAllBytes(Path.Combine(crlfClaude, "crlf.jsonl"), Crlf([
                .. Lines(J("""{"type":"user","uuid":"crlf-human","timestamp":"2026-10-04T04:00:00Z","sessionId":"crlf-claude","message":{"content":[{"type":"text"}]}}"""),
                    Assistant("crlf-1", 400, "2026-10-04T04:00:01Z", "crlf-a")),
                .. Spaces(4_096),
                .. Line(Assistant("crlf-2", 50, "2026-10-04T04:00:07Z", "crlf-b"))]));
            var crlfWhole = new TokenTracker(crlfHome, () => longNow).Sample();
            var crlfTail = new TokenTracker(crlfHome, () => longNow, initialTailBytes: 512).Sample();
            check(crlfWhole.FirstOrDefault(r => r.SessionID == "crlf-codex") is { LastOutputTokens: 100, LastTurnDurationSeconds: 2, Project: "CrlfProject" }
                  && crlfTail.FirstOrDefault(r => r.SessionID == "crlf-claude") is { Active: true, CurrentTurnOutputTokens: 450 },
                  "Windows: CRLF line ends broke the forward read or the backward turn-start scan");

            // Windows (DESIGN rule 8): a writer that keeps the log open and flushes; the next sample must see each line.
            var openHome = Path.Combine(root, "open-writer");
            var openFolder = Path.Combine(openHome, ".codex", "sessions", "2026", "10", "04");
            Directory.CreateDirectory(openFolder);
            var openTracker = new TokenTracker(openHome, () => now);
            using (var writer = new FileStream(Path.Combine(openFolder, "open.jsonl"), FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
            {
                Append(writer, Codex("task_started", "2026-10-04T04:00:00Z", """{"turn_id":"open"}"""));
                var opened = openTracker.Sample().FirstOrDefault();
                Append(writer, Usage(30, 30, "2026-10-04T04:00:01Z"));
                var appended = openTracker.Sample().FirstOrDefault();
                check(opened?.CurrentTurnOutputTokens == 0 && appended?.CurrentTurnOutputTokens == 30 && appended?.LastOutputDelta == 30,
                      "Windows: a line flushed by a writer that keeps the log open was not read on the next sample");
            }
        }
        catch (Exception error)
        {
            c.That(false, $"Incremental file fixture error: {error.Message}");
        }
        finally
        {
            try { Directory.Delete(root, true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return c.Done();
    }
}
