using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenCat;

/// CopilotAmpDroidChecks.swift: Copilot CLI, Amp and Droid fixture checks, run inside `TrackerChecks.Run`, descriptions
/// verbatim. Synthetic metadata only, temp homes.
public static class CopilotAmpDroidChecks
{
    static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-04T12:00:00Z", CultureInfo.InvariantCulture);
    static string Stamp(double seconds) => Start.AddSeconds(seconds).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    static long Ms(double seconds) => Start.AddSeconds(seconds).ToUnixTimeMilliseconds();
    static JsonNode N(string json) => JsonNode.Parse(json)!;
    static byte[] Lines(params JsonNode[] records) => [.. records.SelectMany(record => Encoding.UTF8.GetBytes(record.ToJsonString() + "\n"))];

    static void Write(string path, byte[] data, double? modified = null)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, data);
        if (modified is { } seconds) File.SetLastWriteTimeUtc(path, Start.AddSeconds(seconds).UtcDateTime);
    }

    static void Append(string path, byte[] data)
    {
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        stream.Write(data);
    }

    static JsonNode Event(string type, double at, string data = "{}", string? agent = null)
    {
        var record = new JsonObject { ["type"] = type, ["id"] = Guid.NewGuid().ToString(), ["timestamp"] = Stamp(at), ["data"] = N(data) };
        if (agent is not null) record["agentId"] = agent;
        return record;
    }

    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), $"TokenCat-copilot-amp-droid-{Guid.NewGuid()}");
        try
        {
            // Copilot CLI
            var copilotHome = Path.Combine(root, "copilot");
            var state = Path.Combine(copilotHome, ".copilot", "session-state");
            Write(Path.Combine(state, "copilot-working", "events.jsonl"), Lines(
                Event("session.start", 0, """{"sessionId":"copilot-working","selectedModel":"claude-sonnet-4.5","context":{"cwd":"/tmp/CopilotProject"},"reasoningEffort":"high"}"""),
                Event("user.message", 1, """{"content":"PRIVATE_PROMPT"}"""),
                Event("assistant.turn_start", 2, """{"turnId":"0"}"""),
                Event("assistant.message", 3, """{"messageId":"m1","content":"PRIVATE_REPLY","model":"gpt-5","outputTokens":40,"toolRequests":[{"toolCallId":"c1","name":"bash","arguments":{"command":"PRIVATE"}}]}"""),
                Event("tool.execution_start", 4, """{"toolCallId":"c1","toolName":"bash"}"""),
                Event("assistant.message", 5, """{"messageId":"s1","content":"","model":"sub-model","outputTokens":5}""", agent: "sub-1")));
            Write(Path.Combine(state, "copilot-done", "workspace.yaml"), Encoding.UTF8.GetBytes("id: copilot-done\ncwd: \"/tmp/YamlProject\"\nsummary: PRIVATE_SUMMARY\n"));
            Write(Path.Combine(state, "copilot-done", "events.jsonl"), Lines(
                Event("user.message", 1, """{"content":"PRIVATE"}"""),
                Event("assistant.turn_start", 2, """{"turnId":"0"}"""),
                Event("assistant.message", 3, """{"messageId":"d1","content":"","model":"gpt-5","outputTokens":30,"toolRequests":[{"toolCallId":"d-c1","name":"view"}]}"""),
                Event("tool.execution_start", 4, """{"toolCallId":"d-c1","toolName":"view"}"""),
                Event("tool.execution_complete", 5, """{"toolCallId":"d-c1","success":true}"""),
                Event("assistant.turn_end", 6, """{"turnId":"0"}"""),
                Event("assistant.turn_start", 7, """{"turnId":"1"}"""),
                Event("assistant.message", 8, """{"messageId":"d2","content":"PRIVATE","model":"gpt-5","outputTokens":20}"""),
                Event("assistant.turn_end", 9, """{"turnId":"1"}""")));
            Write(Path.Combine(state, "copilot-permission", "events.jsonl"), Lines(
                Event("user.message", 1, """{"content":"PRIVATE"}"""),
                Event("assistant.message", 2, """{"messageId":"p1","content":"","outputTokens":10,"toolRequests":[{"toolCallId":"p-c1","name":"bash"}]}"""),
                Event("permission.requested", 3, """{"requestId":"perm-1","permissionRequest":{"kind":"shell"}}""")));
            Write(Path.Combine(state, "copilot-crashed", "events.jsonl"), Lines(
                Event("user.message", 1, """{"content":"PRIVATE"}"""),
                Event("assistant.turn_start", 2, """{"turnId":"0"}""")));
            Write(Path.Combine(state, "copilot-crashed", "inuse.2147483.lock"), Encoding.UTF8.GetBytes("2147483\n"));
            var copilotNow = Start.AddSeconds(10);
            var copilotTracker = new TokenTracker(copilotHome, () => copilotNow, environment: _ => null);
            var copilot = copilotTracker.Sample();
            var working = copilot.FirstOrDefault(r => r.SessionID == "copilot-working");
            check(working?.Source == TokenSource.Copilot && working.Active && working.ActivityState == TokenActivityState.Tool
                  && working.ToolName == "bash" && working.ToolCategory == ToolCategory.Other,
                  "Copilot CLI: a running tool after the person's message was not shown as a live tool turn");
            check(working?.CurrentTurnOutputTokens == 45 && working.CurrentTurnStartedAt == Start.AddSeconds(1)
                  && working.RecentOutputs.Select(e => e.Tokens).SequenceEqual([40, 5]) && working.Model == "gpt-5" && working.Effort == "high",
                  "Copilot CLI: outputTokens (subagent output included) or the main model were not counted for the open turn");
            check(working?.Project == "CopilotProject" && working.ProjectPath == "/tmp/CopilotProject",
                  "Copilot CLI: session.start context.cwd was not kept as the project");
            var done = copilot.FirstOrDefault(r => r.SessionID == "copilot-done");
            check(done is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 50, LastTurnDurationSeconds: null, SpeedMeasurement: null },
                  "Copilot CLI: a turn_end after a reply without tool requests must complete the turn with its whole output, no speed");
            check(done?.Project == "YamlProject" && done.ProjectPath == "/tmp/YamlProject",
                  "Copilot CLI: workspace.yaml cwd was not used when the log has no session.start");
            var asking = copilot.FirstOrDefault(r => r.SessionID == "copilot-permission");
            copilotNow = Start.AddSeconds(1_200);
            var later = copilotTracker.Sample();
            check(asking?.ActivityState == TokenActivityState.Input
                  && later.FirstOrDefault(r => r.SessionID == "copilot-permission")?.ActivityState == TokenActivityState.Input
                  && later.FirstOrDefault(r => r.SessionID == "copilot-working")?.ActivityState == TokenActivityState.Stale,
                  "Copilot CLI: a pending permission request must wait for the person while a silent tool turn goes stale");
            var crashed = copilot.FirstOrDefault(r => r.SessionID == "copilot-crashed");
            check(crashed is { Active: false, ActivityState: TokenActivityState.Unfinished },
                  "Copilot CLI: an open turn whose inuse lock names an exited process stayed live");
            check(!Encoding.UTF8.GetString(Json.Serialize(copilot)).Contains("PRIVATE", StringComparison.Ordinal),
                  "Copilot CLI: prompt, reply, tool input or workspace summary text leaked");

            // Amp
            var ampHome = Path.Combine(root, "amp");
            var threads = Path.Combine(ampHome, ".local", "share", "amp", "threads");
            static byte[] Thread(string id, string messages, string ledger = "[]") => Encoding.UTF8.GetBytes(
                $$$"""{"v":3,"id":"{{{id}}}","created":{{{Ms(0)}}},"title":"PRIVATE_TITLE","env":{"initial":{"trees":[{"displayName":"AmpProject","uri":"file:///tmp/AmpProject"}]}},"messages":[{{{messages}}}],"usageLedger":{"events":{{{ledger}}}}}""");
            static string User(int id, double at, string content) =>
                $$$"""{"role":"user","messageId":{{{id}}},"content":{{{content}}},"meta":{"sentAt":{{{Ms(at)}}}}}""";
            static string Reply(int id, double? at, int? tokens, string stop, string? tool = null)
            {
                var content = tool is null ? """[{"type":"text","text":"PRIVATE"}]"""
                    : $$$"""[{"type":"text","text":"PRIVATE"},{"type":"tool_use","id":"{{{tool}}}","name":"Bash","input":{"cmd":"PRIVATE"}}]""";
                var usage = at is { } time && tokens is { } count
                    ? $$$""","usage":{"model":"claude-sonnet-4","outputTokens":{{{count}}},"inputTokens":900,"timestamp":"{{{Stamp(time)}}}"}""" : "";
                return $$$"""{"role":"assistant","messageId":{{{id}}},"state":{"type":"complete","stopReason":"{{{stop}}}"},"content":{{{content}}}{{{usage}}}}""";
            }
            const string Prompt = """[{"type":"text","text":"PRIVATE_PROMPT"}]""";
            static string Result(string id, string status) => $$$"""[{"type":"tool_result","toolUseID":"{{{id}}}","run":{"status":"{{{status}}}"}}]""";
            Write(Path.Combine(threads, "T-working.json"), Thread("T-working",
                string.Join(",", User(0, 1, Prompt), Reply(1, 2, 60, "tool_use", "a-t1"), User(2, 3, Result("a-t1", "in-progress")))), 5);
            Write(Path.Combine(threads, "T-done.json"), Thread("T-done",
                string.Join(",", User(0, 1, Prompt), Reply(1, 2, 70, "tool_use", "d-t1"), User(2, 3, Result("d-t1", "done")), Reply(3, null, null, "end_turn")),
                $$$"""[{"timestamp":"{{{Stamp(4)}}}","model":"claude-sonnet-4","toMessageId":3,"tokens":{"input":10,"output":15}}]"""), 4);
            Write(Path.Combine(threads, "T-blocked.json"), Thread("T-blocked",
                string.Join(",", User(0, 1, Prompt), Reply(1, 2, 8, "tool_use", "b-t1"), User(2, 3, Result("b-t1", "blocked-on-user")))), 3);
            var amp = new TokenTracker(ampHome, () => Start.AddSeconds(10), environment: _ => null).Sample();
            var ampWorking = amp.FirstOrDefault(r => r.SessionID == "T-working");
            check(ampWorking is { Active: true, ActivityState: TokenActivityState.Tool, ToolName: "Bash", CurrentTurnOutputTokens: 60, Model: "claude-sonnet-4" }
                  && ampWorking.CurrentTurnStartedAt == Start.AddSeconds(1),
                  "Amp: a tool still running after a tool_use reply was not a live tool turn with its output and model");
            check(ampWorking?.Project == "AmpProject" && ampWorking.ProjectPath is { } ampPath && ampPath.Replace('\\', '/').EndsWith("/tmp/AmpProject", StringComparison.Ordinal),
                  "Amp: env.initial.trees file URL was not kept as the project");
            var ampDone = amp.FirstOrDefault(r => r.SessionID == "T-done");
            check(ampDone is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 85 }
                  && ampDone.RecentOutputs.Select(e => e.Tokens).SequenceEqual([70, 15]),
                  "Amp: an end_turn reply must complete the turn, counting usageLedger output for a message without usage");
            check(amp.FirstOrDefault(r => r.SessionID == "T-blocked")?.ActivityState == TokenActivityState.Input,
                  "Amp: a tool blocked on the person must wait for input");
            check(amp.Count == 3 && !Encoding.UTF8.GetString(Json.Serialize(amp)).Contains("PRIVATE", StringComparison.Ordinal),
                  "Amp: thread text or title leaked, or a thread was missed");

            // Droid
            var droidHome = Path.Combine(root, "droid");
            var droidFolder = Path.Combine(droidHome, ".factory", "sessions", "-tmp-DroidProject");
            var droidLog = Path.Combine(droidFolder, "droid-session.jsonl");
            var droidSettings = Path.Combine(droidFolder, "droid-session.settings.json");
            static JsonNode Message(string role, double at, string content, string? visibility = null)
            {
                var message = new JsonObject { ["role"] = role, ["content"] = N(content) };
                if (visibility is not null) message["visibility"] = visibility;
                return new JsonObject { ["type"] = "message", ["id"] = Guid.NewGuid().ToString(), ["timestamp"] = Stamp(at), ["message"] = message };
            }
            void Settings(int output, double modified) => Write(droidSettings, Encoding.UTF8.GetBytes(
                $$$"""{"model":"custom:qwen3:30b-[Ollama]-0","reasoningEffort":"high","tokenUsage":{"inputTokens":5000,"outputTokens":{{{output}}},"thinkingTokens":0}}"""), modified);
            Write(droidLog, Lines(
                N("""{"type":"session_start","id":"droid-session","title":"PRIVATE_TITLE","cwd":"/tmp/DroidProject","version":2}"""),
                Message("user", 0, """[{"type":"text","text":"PRIVATE_CONTEXT"}]""", "llm_only"),
                Message("user", 0.1, """[{"type":"text","text":"PRIVATE_PROMPT"}]"""),
                Message("assistant", 1, """[{"type":"thinking","thinking":"PRIVATE"},{"type":"tool_use","id":"dr-t1","name":"Execute","input":{"command":"PRIVATE"}}]""")));
            Settings(100, 1);
            var droidNow = Start.AddSeconds(2);
            var droidTracker = new TokenTracker(droidHome, () => droidNow, environment: _ => null);
            var droidOpen = droidTracker.Sample().FirstOrDefault();
            check(droidOpen is { Source: TokenSource.Droid, Active: true, ActivityState: TokenActivityState.Tool, ToolName: "Execute",
                      CurrentTurnOutputTokens: null, Model: "qwen3:30b", Effort: "high", Project: "DroidProject" },
                  "Droid: an open tool turn read cold lost its model or project, or counted output from before its known total");
            Append(droidLog, Lines(Message("user", 3, """[{"type":"tool_result","tool_use_id":"dr-t1","content":"PRIVATE"}]"""),
                                   Message("assistant", 4, """[{"type":"text","text":"PRIVATE"}]""")));
            droidNow = Start.AddSeconds(5);
            var droidClosed = droidTracker.Sample().FirstOrDefault();
            check(droidClosed is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: null },
                  "Droid: a text reply after the tool result must complete the turn without inventing its output");
            Append(droidLog, Lines(Message("user", 20, """[{"type":"text","text":"PRIVATE_PROMPT"}]""")));
            droidNow = Start.AddSeconds(21);
            var droidNext = droidTracker.Sample().FirstOrDefault();
            check(droidNext is { ActivityState: TokenActivityState.Working, CurrentTurnOutputTokens: 0 } && droidNext.CurrentTurnStartedAt == Start.AddSeconds(20),
                  "Droid: a new prompt after a known total must start a counted turn at zero");
            Settings(160, 25);
            Append(droidLog, Lines(Message("assistant", 26, """[{"type":"text","text":"PRIVATE"}]""")));
            droidNow = Start.AddSeconds(27);
            var droidDone = droidTracker.Sample().FirstOrDefault();
            check(droidDone is { ActivityState: TokenActivityState.Complete, LastOutputTokens: 60 }
                  && droidDone.RecentOutputs.LastOrDefault() is { Tokens: 60 } last && last.At == Start.AddSeconds(25),
                  "Droid: growth of the settings output total was not logged at its write time and credited to the turn");
            check(!Encoding.UTF8.GetString(Json.Serialize(droidDone)).Contains("PRIVATE", StringComparison.Ordinal)
                  && DroidLogReader.ModelName(JsonDocument.Parse("\"claude-opus-4-1\"").RootElement) == "claude-opus-4-1",
                  "Droid: transcript text leaked, or a plain model name was rewritten");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            check(false, $"Copilot/Amp/Droid fixtures could not be written: {error.Message}");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}
