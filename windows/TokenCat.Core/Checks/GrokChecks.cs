using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace TokenCat;

/// GrokChecks.swift: Grok Build fixture checks, run inside `TrackerChecks.Run`, descriptions verbatim. Synthetic metadata
/// only, temp homes.
public static class GrokChecks
{
    static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-04T12:00:00Z", CultureInfo.InvariantCulture);
    static string Stamp(double seconds) => Start.AddSeconds(seconds).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    static JsonNode N(string json) => JsonNode.Parse(json)!;
    static byte[] Lines(params JsonNode[] records) => [.. records.SelectMany(record => Encoding.UTF8.GetBytes(record.ToJsonString() + "\n"))];

    static void Write(string path, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, data);
    }

    static void Append(string path, byte[] data)
    {
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        stream.Write(data);
    }

    static JsonNode Event(string type, double at, string fields = "{}")
    {
        var record = N(fields).AsObject();
        record["type"] = type;
        record["ts"] = Stamp(at);
        return record;
    }

    static JsonNode Update(string session, double at, string update) => new JsonObject
    {
        ["method"] = "_x.ai/session/update",
        ["timestamp"] = (long)Start.AddSeconds(at).ToUnixTimeSeconds(),
        ["params"] = new JsonObject
        {
            ["sessionId"] = session, ["update"] = N(update),
            ["_meta"] = new JsonObject { ["eventId"] = $"{session}-{(int)at}", ["agentTimestampMs"] = Start.AddSeconds(at).ToUnixTimeMilliseconds() },
        },
    };

    static JsonNode Inference(string session, double at, int output, int prompt, int elapsed) => new JsonObject
    {
        ["ts"] = Stamp(at), ["src"] = "shell", ["pid"] = 42, ["ver"] = "1.0.5", ["lvl"] = "info", ["sid"] = session,
        ["msg"] = "shell.turn.inference_done",
        ["ctx"] = new JsonObject
        {
            ["loop_index"] = 1, ["model_elapsed_ms"] = elapsed, ["ttft_ms"] = 500, ["attempts"] = 1, ["prompt_tokens"] = prompt,
            ["cached_prompt_tokens"] = prompt / 2, ["completion_tokens"] = output, ["reasoning_tokens"] = output / 2, ["tokens_per_sec"] = 1,
        },
    };

    public static void Run(Action<bool, string> check)
    {
        var home = Path.Combine(Path.GetTempPath(), $"TokenCat-grok-{Guid.NewGuid()}");
        try
        {
            var grok = Path.Combine(home, ".grok");
            var sessions = Path.Combine(grok, "sessions");
            var project = Path.Combine(sessions, "%2Ftmp%2FGrokProject");
            var main = Path.Combine(project, "grok-main");
            var unified = Path.Combine(grok, "logs", "unified.jsonl");
            Write(Path.Combine(main, "summary.json"), Lines(N($$"""
                {"info":{"id":"grok-main","cwd":"/tmp/GrokProject"},"session_summary":"PRIVATE_SUMMARY","generated_title":"Fix login flow",
                 "current_model_id":"grok-fixture","reasoning_effort":"high","context_window":256000,"created_at":"{{Stamp(0)}}",
                 "updated_at":"{{Stamp(0)}}","num_messages":2}
                """)));
            Write(Path.Combine(main, "events.jsonl"), Lines(
                Event("turn_started", 0, """{"session_id":"grok-main","turn_number":0,"model_id":"grok-fixture","yolo_mode":false,"conversation_message_count":1,"session_relationship":"primary","schema_version":"1.0"}"""),
                Event("loop_started", 1, """{"loop_index":0}"""),
                Event("phase_changed", 1, """{"phase":"waiting_for_model"}"""),
                Event("phase_changed", 3, """{"phase":"streaming_text"}"""),
                Event("tool_started", 5, """{"tool_name":"run_terminal_command"}""")));
            Write(Path.Combine(main, "updates.jsonl"), Lines(
                Update("grok-main", 0, """{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"PRIVATE_PROMPT"}}"""),
                Update("grok-main", 3, """{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"PRIVATE_REPLY"}}"""),
                Update("grok-main", 5, """{"sessionUpdate":"tool_call","toolCallId":"c1","title":"run_terminal_command","status":"pending","rawInput":{"command":"PRIVATE_COMMAND"}}""")));
            Write(unified, Lines(
                N($$$"""{"ts":"{{{Stamp(0)}}}","src":"shell","pid":42,"lvl":"info","msg":"session created","ctx":{"cwd":"/tmp/GrokProject"}}"""),
                Inference("grok-main", 4, output: 40, prompt: 12_000, elapsed: 2_000),
                Inference("grok-elsewhere", 4, output: 900, prompt: 1, elapsed: 1_000),
                N($$$"""{"ts":"{{{Stamp(4)}}}","src":"shell","pid":42,"lvl":"error","sid":"grok-main","msg":"turn.terminal_failure","ctx":{"message":"PRIVATE_ERROR"}}""")));

            var now = Start.AddSeconds(6);
            var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            var row = tracker.Sample().FirstOrDefault(r => r.SessionID == "grok-main");
            check(row?.Source == TokenSource.Grok && row.Active && row.ActivityState == TokenActivityState.Tool && row.ToolName == "run_terminal_command"
                  && row.ToolCategory == ToolCategory.Command && row.CurrentTurnOutputTokens == 40 && row.CurrentTurnStartedAt == Start
                  && row.Model == "grok-fixture" && row.Effort == "high" && row.Project == "GrokProject"
                  && row.ProjectPath == "/tmp/GrokProject" && row.Title == "Fix login flow" && !row.IsSubagent
                  && row.Context?.UsedTokens == 12_000 && row.Context?.WindowTokens == 256_000,
                  "Grok: an open turn running a tool was not a tool turn with its output, model, effort, project, title and context");
            check(row?.SpeedMeasurement?.OutputTokens == 40 && row.SpeedMeasurement.RequestDurationMs == 2_000
                  && row.SpeedMeasurement.TtftMs == 500 && row.SpeedMeasurement.TokensPerSecond == 20
                  && row.SpeedMeasurement.Model == "grok-fixture" && !row.SpeedMeasurement.RequestDurationIncludesRetries,
                  "Grok: a unified-log model call's own timing was not reported as a measured request rate");

            Append(Path.Combine(main, "events.jsonl"), Lines(Event("permission_requested", 7, """{"tool_name":"run_terminal_command"}""")));
            now = Start.AddSeconds(3_600);
            row = tracker.Sample().FirstOrDefault(r => r.SessionID == "grok-main");
            check(row is { Active: true, ActivityState: TokenActivityState.Input, ToolName: "run_terminal_command" },
                  "Grok: an hour-old permission prompt was not live input");

            Append(Path.Combine(main, "events.jsonl"), Lines(
                Event("permission_resolved", 3_601, """{"tool_name":"run_terminal_command","decision":"allow","wait_ms":3594000}"""),
                Event("tool_completed", 3_602, """{"tool_name":"run_terminal_command","duration_ms":900,"outcome":"success","tool_call_id":"c1"}"""),
                Event("phase_changed", 3_603, """{"phase":"waiting_for_model"}"""),
                Event("turn_ended", 3_605, """{"outcome":"completed"}""")));
            Append(unified, Lines(Inference("grok-main", 3_604, output: 60, prompt: 13_000, elapsed: 3_000)));
            Append(Path.Combine(main, "updates.jsonl"), Lines(Update("grok-main", 3_605,
                """{"sessionUpdate":"turn_completed","prompt_id":"p1","stop_reason":"end_turn","agent_result":"PRIVATE_RESULT","elapsed_ms":3605000,"usage":{"inputTokens":25000,"outputTokens":999,"modelCalls":2}}""")));
            now = Start.AddSeconds(3_610);
            row = tracker.Sample().FirstOrDefault(r => r.SessionID == "grok-main");
            check(row is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 100, ToolName: null, CurrentTurnOutputTokens: null }
                  && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([60]) && row.LastTurnDurationSeconds == 3_605
                  && row.Context?.UsedTokens == 13_000 && row.SpeedMeasurement?.TokensPerSecond == 20,
                  "Grok: a completed turn did not total its unified-log calls once (turn_completed usage counted again), or lost its duration");

            // Grok trims unified.jsonl to its newer half in place: lines read again are not new calls.
            using (var stream = new FileStream(unified, FileMode.Open, FileAccess.Write, FileShare.ReadWrite))
            {
                stream.SetLength(0);
                stream.Write(Lines(Inference("grok-main", 3_604, output: 60, prompt: 13_000, elapsed: 3_000)));
            }
            row = tracker.Sample().FirstOrDefault(r => r.SessionID == "grok-main");
            check(row?.LastOutputTokens == 100 && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([60]),
                  "Grok: lines kept by a unified-log trim were counted again");

            // A session the unified log does not cover: turn_completed usage counts; a /rename title shows.
            var renamed = Path.Combine(project, "grok-renamed");
            Write(Path.Combine(renamed, "summary.json"), Lines(N("""
                {"info":{"id":"grok-renamed","cwd":"/tmp/GrokProject"},"generated_title":"Renamed by person","title_is_manual":true,
                 "session_summary":"PRIVATE","current_model_id":"grok-fixture"}
                """)));
            Write(Path.Combine(renamed, "events.jsonl"), Lines(
                Event("turn_started", 3_620, """{"model_id":"grok-fixture","session_relationship":"primary"}"""),
                Event("turn_ended", 3_630, """{"outcome":"completed"}""")));
            Write(Path.Combine(renamed, "updates.jsonl"), Lines(Update("grok-renamed", 3_629,
                """{"sessionUpdate":"turn_completed","prompt_id":"p","stop_reason":"end_turn","usage":{"outputTokens":77}}""")));
            // A slug-and-hash cwd folder names its path in `.cwd`. A failed title request leaves the first prompt's opening
            // words as the title, which never shows. A /fork names its parent but stays top-level.
            var longGroup = Path.Combine(sessions, "longproject-0123456789abcdef");
            Write(Path.Combine(longGroup, ".cwd"), Encoding.UTF8.GetBytes("/tmp/LongProject\n"));
            var untitled = Path.Combine(longGroup, "grok-untitled");
            Write(Path.Combine(untitled, "summary.json"), Lines(N("""
                {"session_summary":"PRIVATE opening words of the prompt","generated_title":"PRIVATE opening words of the prompt",
                 "session_kind":"fork","parent_session_id":"grok-main","current_model_id":"grok-fixture"}
                """)));
            Write(Path.Combine(untitled, "events.jsonl"), Lines(
                Event("turn_started", 3_620, """{"model_id":"grok-fixture"}"""),
                Event("turn_ended", 3_625, """{"outcome":"cancelled"}""")));
            Write(Path.Combine(untitled, "updates.jsonl"), Lines(
                Update("grok-untitled", 3_619, """{"sessionUpdate":"hook_execution","event_name":"session_start"}"""),
                Update("grok-untitled", 3_620, """{"sessionUpdate":"user_message_chunk","_meta":{"promptIndex":0},"content":{"type":"text","text":"PRIVATE opening\nwords of the  prompt and more"}}""")));
            // A subagent running in a worktree: the parent's subagents/<id>/meta.json names its parent and type.
            var child = Path.Combine(sessions, "%2Ftmp%2FGrokWorktree", "grok-child");
            Write(Path.Combine(child, "summary.json"), Lines(N("""
                {"info":{"id":"grok-child","cwd":"/tmp/GrokWorktree"},"session_kind":"subagent","agent_name":"general-purpose",
                 "current_model_id":"grok-sub","session_summary":"PRIVATE"}
                """)));
            Write(Path.Combine(child, "events.jsonl"), Lines(
                Event("turn_started", 3_620, """{"model_id":"grok-sub","session_relationship":"primary"}"""),
                Event("tool_started", 3_622, """{"tool_name":"read_file"}""")));
            Write(Path.Combine(child, "updates.jsonl"), Lines(
                Update("grok-child", 3_620, """{"sessionUpdate":"user_message_chunk","content":{"text":"PRIVATE_TASK"}}""")));
            Write(Path.Combine(main, "subagents", "grok-child", "meta.json"), Lines(N("""
                {"subagent_id":"grok-child","parent_session_id":"grok-main","child_session_id":"grok-child","subagent_type":"explore",
                 "description":"PRIVATE_DESCRIPTION","prompt":"PRIVATE_PROMPT"}
                """)));
            Append(unified, Lines(Inference("grok-child", 3_621, output: 7, prompt: 900, elapsed: 700)));
            now = Start.AddSeconds(3_632);
            var rows = tracker.Sample().Where(r => r.Source == TokenSource.Grok).ToList();
            var renamedRow = rows.FirstOrDefault(r => r.SessionID == "grok-renamed");
            check(renamedRow is { ActivityState: TokenActivityState.Complete, LastOutputTokens: 77, Title: "Renamed by person", SpeedMeasurement: null },
                  "Grok: a turn outside the unified log did not count its turn_completed usage, or a renamed title was not shown");
            var untitledRow = rows.FirstOrDefault(r => r.SessionID == "grok-untitled");
            check(untitledRow is { Title: null, Project: "LongProject", ProjectPath: "/tmp/LongProject", ActivityState: TokenActivityState.Interrupted,
                                   IsSubagent: false, ParentSessionID: null },
                  "Grok: a fallback title copied from the first prompt showed, a .cwd folder lost its path, or a fork became a subagent");
            var childRow = rows.FirstOrDefault(r => r.SessionID == "grok-child");
            check(childRow is { IsSubagent: true, ParentSessionID: "grok-main", AgentID: "grok-child", AgentRole: "explore",
                                ActivityState: TokenActivityState.Tool, ToolName: "read_file", ToolCategory: ToolCategory.File,
                                CurrentTurnOutputTokens: 7, Model: "grok-sub", Project: "GrokWorktree", Title: null },
                  "Grok: a worktree subagent was not grouped under its parent with its type, tool and output");
            check(rows.Count == 4 && !Encoding.UTF8.GetString(Json.Serialize(rows)).Contains("PRIVATE", StringComparison.Ordinal),
                  "Grok: message text leaked into a reading, or a session row is missing");
            check(tracker.IsLog(Path.Combine(main, "updates.jsonl")) && !tracker.IsLog(Path.Combine(main, "events.jsonl"))
                  && !tracker.IsLog(Path.Combine(main, "subagents", "grok-child", "meta.json")) && !tracker.IsLog(unified),
                  "Grok: file events of the session update log were ignored, or other Grok files woke sampling");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            check(false, $"Grok fixtures could not be written: {error}");
        }
        finally
        {
            try { Directory.Delete(home, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}
