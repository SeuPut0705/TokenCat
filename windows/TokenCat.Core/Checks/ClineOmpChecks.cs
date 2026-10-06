using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenCat;

/// ClineOmpChecks.swift: Cline / Roo Code / Cline CLI and omp / Pi fixture files (synthetic metadata, no transcript text) — a
/// working turn, a tool, a finished turn, waiting for the person, token totals, model, project, subagents and omp's measured
/// request rate. Run from `TrackerChecks.Run`; descriptions verbatim.
public static class ClineOmpChecks
{
    static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-04T05:00:00Z", CultureInfo.InvariantCulture);
    static string Iso(double seconds) => Start.AddSeconds(seconds).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    static long Ms(double seconds) => Start.AddSeconds(seconds).ToUnixTimeMilliseconds();
    static JsonNode N(string json) => JsonNode.Parse(json)!;

    static void Append(string path, params JsonNode[] records)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        stream.Write(Encoding.UTF8.GetBytes(string.Concat(records.Select(record => record.ToJsonString() + "\n"))));
    }

    static void Write(string path, JsonNode value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, value.ToJsonString());
    }

    public static void Run(string root, Action<bool, string> check)
    {
        var now = Start;
        try
        {
            // omp: a main session and a subagent in its session folder.
            var home = Path.Combine(root, "omp-home");
            var project = Path.Combine(home, ".omp", "agent", "sessions", "--tmp-Fixture-OmpProject--");
            const string stem = "2026-10-04T05-00-00-000Z_omp-main";
            var main = Path.Combine(project, stem + ".jsonl");
            JsonNode Message(double seconds, JsonNode body) =>
                new JsonObject { ["type"] = "message", ["id"] = Guid.NewGuid().ToString(), ["timestamp"] = Iso(seconds), ["message"] = body };
            JsonNode Assistant(double seconds, int output, string stop, (string Id, string Name)? tool = null)
            {
                var content = new JsonArray { N("""{"type":"text","text":"PRIVATE_REPLY"}""") };
                if (tool is { } call)
                    content.Add(new JsonObject { ["type"] = "toolCall", ["id"] = call.Id, ["name"] = call.Name, ["arguments"] = N("""{"command":"PRIVATE_CMD"}""") });
                return Message(seconds, new JsonObject
                {
                    ["role"] = "assistant", ["model"] = "omp-model", ["provider"] = "fixture", ["stopReason"] = stop,
                    ["timestamp"] = Ms(seconds - 2), ["completedAt"] = Ms(seconds), ["duration"] = 2_000, ["ttft"] = 500,
                    ["usage"] = new JsonObject { ["input"] = 10, ["output"] = output, ["cacheRead"] = 9_000, ["cacheWrite"] = 990 },
                    ["content"] = content,
                });
            }
            JsonNode User(double seconds) => Message(seconds, new JsonObject { ["role"] = "user", ["content"] = "PRIVATE_PROMPT", ["timestamp"] = Ms(seconds) });
            Append(main, N("""{"type":"title","title":"PRIVATE_TITLE"}"""),
                new JsonObject { ["type"] = "session", ["version"] = 3, ["id"] = "omp-main", ["timestamp"] = Iso(0), ["cwd"] = "/tmp/Fixture/OmpProject" },
                new JsonObject { ["type"] = "model_change", ["timestamp"] = Iso(0), ["model"] = "fixture/omp-model" },
                new JsonObject { ["type"] = "thinking_level_change", ["timestamp"] = Iso(0), ["thinkingLevel"] = "high" },
                User(1), Assistant(4, 40, "toolUse", ("call-1", "bash")));
            now = Start.AddSeconds(5);
            var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            var row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { Source: TokenSource.Omp, Active: true, ActivityState: TokenActivityState.Tool, ToolName: "bash", ToolCategory: ToolCategory.Command,
                      CurrentTurnOutputTokens: 40, Model: "omp-model", Project: "OmpProject", ProjectPath: "/tmp/Fixture/OmpProject", SessionID: "omp-main",
                      Effort: "high", Context.UsedTokens: 10_000 }
                  && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([40]),
                  "omp: a reply calling a tool was not a running tool turn with its output, model, effort, context and project");
            check(row?.SpeedMeasurement is { OutputTokens: 40, RequestDurationMs: 2_000, TtftMs: 500, Model: "omp-model", TokensPerSecond: 20 },
                  "omp: the client's own request duration was not reported as a measured request rate");

            Append(main, Message(6, new JsonObject { ["role"] = "toolResult", ["toolCallId"] = "call-1", ["toolName"] = "bash", ["content"] = "PRIVATE_OUT", ["timestamp"] = Ms(6) }),
                Assistant(9, 60, "stop"));
            now = Start.AddSeconds(10);
            row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 100, CurrentTurnOutputTokens: null }
                  && row.RecentOutputs.Select(e => e.Tokens).SequenceEqual([40, 60]),
                  "omp: a final reply did not finish the turn with its whole output");

            Append(main, User(20), Assistant(23, 7, "toolUse", ("call-2", "ask")));
            now = Start.AddSeconds(7_200);
            row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { Active: true, ActivityState: TokenActivityState.Input, ToolCategory: ToolCategory.Question, CurrentTurnOutputTokens: 7, LastOutputTokens: 100 },
                  "omp: a two-hour-old question to the person was not live input");

            var agent = Path.Combine(project, stem, "Scout.jsonl");
            Append(agent,
                new JsonObject { ["type"] = "session", ["id"] = "omp-agent", ["timestamp"] = Iso(7_190), ["cwd"] = "/tmp/Fixture/OmpProject", ["parentSession"] = main },
                new JsonObject { ["type"] = "session_init", ["timestamp"] = Iso(7_190), ["agent"] = "scout", ["task"] = "PRIVATE_TASK" },
                User(7_191), Assistant(7_195, 12, "toolUse", ("call-3", "yield")),
                Message(7_196, new JsonObject { ["role"] = "toolResult", ["toolCallId"] = "call-3", ["toolName"] = "yield", ["timestamp"] = Ms(7_196) }),
                new JsonObject { ["type"] = "custom", ["customType"] = "session_exit", ["timestamp"] = Iso(7_196), ["data"] = N("""{"kind":"normal"}""") });
            var sampled = tracker.Sample();
            var child = sampled.FirstOrDefault(r => r.IsSubagent);
            check(child is { ParentSessionID: "omp-main", SessionID: "omp-agent", AgentRole: "scout", ActivityState: TokenActivityState.Complete,
                      Active: false, LastOutputTokens: 12 }
                  && child.AgentID?.EndsWith("/Scout", StringComparison.Ordinal) == true,
                  "omp: a subagent was not grouped under its root session, named, or finished by its exit record");
            check(!JsonSerializer.Serialize(sampled).Contains("PRIVATE", StringComparison.Ordinal),
                  "omp: message text, a title or tool arguments leaked into a reading");

            Append(main, Assistant(7_201, 3, "aborted"));
            now = Start.AddSeconds(7_202);
            row = tracker.Sample().FirstOrDefault(r => !r.IsSubagent);
            check(row is { Active: false, ActivityState: TokenActivityState.Interrupted }, "omp: an aborted reply did not end the turn as interrupted");
        }
        catch (Exception error)
        {
            check(false, $"omp fixture error: {error.Message}");
        }

        try
        {
            // Cline in VS Code, Roo Code in Cursor, and the Cline CLI.
            var home = Path.Combine(root, "cline-home");
            var storage = Path.Combine(home, "AppData", "Roaming");
            var clineTask = Path.Combine(storage, "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "tasks", "1791100000000");
            var rooTask = Path.Combine(storage, "Cursor", "User", "globalStorage", "rooveterinaryinc.roo-cline", "tasks", "roo-task");
            var session = Path.Combine(home, ".cline", "data", "sessions", "cli-1");
            foreach (var folder in new[] { clineTask, rooTask, session }) Directory.CreateDirectory(folder);
            JsonNode Say(double seconds, string kind, string text = "PRIVATE_TEXT", string? model = null)
            {
                var value = new JsonObject { ["ts"] = Ms(seconds), ["type"] = "say", ["say"] = kind, ["text"] = text };
                if (model is not null) value["modelInfo"] = new JsonObject { ["modelId"] = model, ["providerId"] = "fixture", ["mode"] = "act" };
                return value;
            }
            JsonNode Request(double seconds, int? output, string? model = "cline-model")
            {
                var info = new JsonObject { ["request"] = "PRIVATE_REQUEST" };
                if (output is { } tokens)
                {
                    info["tokensIn"] = 10;
                    info["tokensOut"] = tokens;
                    info["cacheReads"] = 0;
                    info["cacheWrites"] = 0;
                    info["cost"] = 0.01;
                }
                return Say(seconds, "api_req_started", info.ToJsonString(), model);
            }
            JsonNode Ask(double seconds, string kind) => new JsonObject { ["ts"] = Ms(seconds), ["type"] = "ask", ["ask"] = kind, ["text"] = "PRIVATE_ASK" };
            const string history = """[{"role":"user","content":[{"type":"text","text":"PRIVATE <environment_details>\n""";
            File.WriteAllText(Path.Combine(clineTask, "api_conversation_history.json"),
                history + """# Current Working Directory (/tmp/Fixture/ClineProject) Files\n</environment_details>"}]}]""");
            var clineLog = Path.Combine(clineTask, "ui_messages.json");
            var readFile = Say(4, "tool", """{"tool":"readFile","path":"PRIVATE_PATH"}""");
            Write(clineLog, new JsonArray(Say(0, "text"), Request(1, 30), Say(3, "text"), readFile.DeepClone(), Request(5, null)));
            now = Start.AddSeconds(6);
            var tracker = new TokenTracker(home, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            var cline = tracker.Sample().FirstOrDefault(r => r.SessionID == "1791100000000");
            check(cline is { Source: TokenSource.Cline, Active: true, ActivityState: TokenActivityState.Working, CurrentTurnOutputTokens: 30, Model: "cline-model",
                      Project: "ClineProject", ProjectPath: "/tmp/Fixture/ClineProject", SpeedMeasurement: null }
                  && cline.RecentOutputs.Select(e => e.Tokens).SequenceEqual([30]) && cline.RecentOutputs[0].At == Start.AddSeconds(4),
                  "Cline: an in-flight request was not a working turn with the earlier request's output, model and project");

            Write(clineLog, new JsonArray(Say(0, "text"), Request(1, 30), Say(3, "text"), readFile.DeepClone(), Request(5, 50),
                Say(8, "completion_result"), Ask(8, "completion_result")));
            now = Start.AddSeconds(9);
            cline = tracker.Sample().FirstOrDefault(r => r.SessionID == "1791100000000");
            check(cline is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 80, CurrentTurnOutputTokens: null }
                  && cline.RecentOutputs.Select(e => e.Tokens).SequenceEqual([30, 50]),
                  "Cline: a completion did not finish the turn with its whole output");

            File.WriteAllText(Path.Combine(rooTask, "api_conversation_history.json"),
                history + """# Current Workspace Directory (/tmp/Fixture/RooProject) Files\n\n# Current Mode\n<model>roo-model</model>\n</environment_details>"}]}]""");
            Write(Path.Combine(rooTask, "ui_messages.json"), new JsonArray(Say(0, "text"), Request(1, 20, model: null), Say(3, "text"), Ask(4, "followup")));
            now = Start.AddSeconds(7_200);
            var roo = tracker.Sample().FirstOrDefault(r => r.SessionID == "roo-task");
            check(roo is { Active: true, ActivityState: TokenActivityState.Input, ToolCategory: ToolCategory.Question, Model: "roo-model",
                      Project: "RooProject", CurrentTurnOutputTokens: 20 },
                  "Roo Code: a two-hour-old question was not live input, or its model and workspace were not read");

            var manifest = Path.Combine(session, "cli-1.json");
            void WriteManifest(string status) => Write(manifest, new JsonObject
            {
                ["version"] = 1, ["session_id"] = "cli-1", ["source"] = "cli", ["pid"] = 1, ["started_at"] = Iso(7_250), ["status"] = status,
                ["interactive"] = true, ["provider"] = "fixture", ["model"] = "manifest-model", ["cwd"] = "/tmp/Fixture/CliProject",
                ["workspace_root"] = "/tmp/Fixture/CliProject", ["prompt"] = "PRIVATE_PROMPT",
            });
            WriteManifest("running");
            var messages = Path.Combine(session, "cli-1.messages.json");
            Write(messages, new JsonObject
            {
                ["messages"] = new JsonArray(
                    new JsonObject { ["role"] = "user", ["content"] = "PRIVATE_PROMPT", ["ts"] = Ms(7_250) },
                    new JsonObject
                    {
                        ["role"] = "assistant", ["ts"] = Ms(7_260), ["modelInfo"] = N("""{"id":"cli-model","provider":"fixture"}"""),
                        ["metrics"] = N("""{"inputTokens":100,"outputTokens":25}"""),
                        ["content"] = N("""[{"type":"tool_use","id":"t1","name":"bash","input":{"command":"PRIVATE_CMD"}}]"""),
                    }),
            });
            now = Start.AddSeconds(7_270);
            var cli = tracker.Sample().FirstOrDefault(r => r.SessionID == "cli-1");
            check(cli is { Active: true, ActivityState: TokenActivityState.Tool, ToolName: "bash", CurrentTurnOutputTokens: 25, Model: "cli-model", Project: "CliProject" },
                  "Cline CLI: a running session calling a tool was not a tool turn with its output, model and project");
            WriteManifest("completed");
            cli = tracker.Sample().FirstOrDefault(r => r.SessionID == "cli-1");
            check(cli is { Active: false, ActivityState: TokenActivityState.Complete, LastOutputTokens: 25 }
                  && !JsonSerializer.Serialize(tracker.Sample()).Contains("PRIVATE", StringComparison.Ordinal),
                  "Cline CLI: a completed session did not finish its turn, or message text leaked into a reading");
            check(tracker.IsLog(clineLog) && tracker.IsLog(messages) && !tracker.IsLog(manifest)
                  && !tracker.IsLog(Path.Combine(clineTask, "api_conversation_history.json")),
                  "Cline: a changed path was matched to the wrong file of a task or session");
        }
        catch (Exception error)
        {
            check(false, $"Cline fixture error: {error.Message}");
        }
    }
}
