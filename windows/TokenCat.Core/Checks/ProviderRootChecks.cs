using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace TokenCat;

/// ProviderRootChecks.swift: data folders and environment overrides of clients read by an existing format, and the products
/// that write one of those formats into their own folders (`TokenClientRoots`). Temp homes with environment dictionaries,
/// synthetic metadata only. Run inside `TrackerChecks.Run`, descriptions verbatim. The Gemini CLI Seatbelt sandbox root is
/// macOS-only and has no check here.
public static class ProviderRootChecks
{
    static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-04T04:00:00Z", CultureInfo.InvariantCulture);
    static readonly DateTimeOffset Now = Start.AddSeconds(10);
    static string Iso(double seconds) => Start.AddSeconds(seconds).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    static long Ms(double seconds) => Start.AddSeconds(seconds).ToUnixTimeMilliseconds();
    static JsonNode N(string json) => JsonNode.Parse(json)!;

    static void Write(string path, params JsonNode[] records)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, string.Concat(records.Select(record => record.ToJsonString() + "\n")));
    }

    static bool Leaks(IEnumerable<TokenReading> rows) => Encoding.UTF8.GetString(Json.Serialize(rows.ToList())).Contains("PRIVATE", StringComparison.Ordinal);

    static bool Running(TokenReading? row, string tool) => row is { Active: true, ActivityState: TokenActivityState.Tool } && row.ToolName == tool;

    /// A resume command for the row with a Windows project folder (fixture folders are POSIX paths).
    static string? Resume(TokenReading? row) => row is null ? null : SessionPresentation.ResumeCommand(row with { ProjectPath = @"C:\work" });

    /// A Codex rollout in a running turn: an exec call after a usage-limit snapshot.
    static void Rollout(string path, string session)
    {
        JsonNode Event(string type, double at, JsonObject? extra = null)
        {
            var payload = extra ?? new JsonObject();
            payload["type"] = type;
            return new JsonObject { ["type"] = "event_msg", ["timestamp"] = Iso(at), ["payload"] = payload };
        }
        Write(path,
            new JsonObject { ["type"] = "session_meta", ["timestamp"] = Iso(0),
                             ["payload"] = new JsonObject { ["id"] = session, ["cwd"] = "/tmp/Fixture/RolloutProject", ["timestamp"] = Iso(0) } },
            new JsonObject { ["type"] = "turn_context", ["timestamp"] = Iso(0), ["payload"] = N("""{"model":"gpt-fixture","effort":"high"}""") },
            Event("task_started", 1, new JsonObject { ["turn_id"] = "t1" }),
            Event("token_count", 2, (JsonObject)N("""
                {"info":{"total_token_usage":{"output_tokens":10},"last_token_usage":{"output_tokens":10,"input_tokens":500},"model_context_window":258400},
                 "rate_limits":{"limit_id":"codex","primary":{"used_percent":42,"window_minutes":10080,"resets_at":1791400000}}}
                """)),
            new JsonObject { ["type"] = "response_item", ["timestamp"] = Iso(3),
                             ["payload"] = N("""{"type":"custom_tool_call","call_id":"c1","name":"exec","input":"PRIVATE_CMD"}""") });
    }

    /// A Claude Code transcript whose reply is running a Bash call.
    static void Transcript(string path, string session) =>
        Write(path,
            new JsonObject { ["type"] = "user", ["uuid"] = session + "-in", ["timestamp"] = Iso(1), ["sessionId"] = session, ["cwd"] = "/tmp/Fixture/ClaudeProject",
                             ["origin"] = N("""{"kind":"human"}"""), ["message"] = N("""{"role":"user","content":"PRIVATE_PROMPT"}""") },
            new JsonObject { ["type"] = "assistant", ["uuid"] = session + "-out", ["timestamp"] = Iso(2), ["sessionId"] = session, ["cwd"] = "/tmp/Fixture/ClaudeProject",
                             ["message"] = new JsonObject { ["id"] = session + "-msg", ["model"] = "claude-fixture", ["usage"] = N("""{"output_tokens":30}"""),
                                 ["content"] = new JsonArray { new JsonObject { ["type"] = "tool_use", ["id"] = session + "-tool", ["name"] = "Bash",
                                                                                ["input"] = N("""{"command":"PRIVATE_CMD"}""") } } } });

    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "tokencat-provider-roots-" + Guid.NewGuid().ToString("N"));
        try
        {
            CodexRoots(root, check);
            ClaudeRoots(root, check);
            DroidRoots(root, check);
            ClineRoots(root, check);
            OmpRoots(root, check);
        }
        finally
        {
            try { Directory.Delete(root, true); } catch (Exception) { }
        }
    }

    static void CodexRoots(string root, Action<bool, string> check)
    {
        try
        {
            // Codex: CODEX_HOME, with ~\.codex kept; TRAE CLI (a codex-rs fork) in ~\.trae\cli\sessions and TRAEX_SESSIONS_DIR.
            var home = Path.Combine(root, "codex-home");
            var codexHome = Path.Combine(root, "elsewhere", "codex");
            var traeDir = Path.Combine(root, "elsewhere", "traex");
            Rollout(Path.Combine(codexHome, "sessions", "2026", "10", "04", "moved.jsonl"), "codex-moved");
            Rollout(Path.Combine(home, ".codex", "sessions", "2026", "10", "04", "default.jsonl"), "codex-default");
            Rollout(Path.Combine(home, ".trae", "cli", "sessions", "2026", "10", "04", "trae.jsonl"), "trae-default");
            Rollout(Path.Combine(traeDir, "2026", "10", "04", "trae.jsonl"), "trae-moved");
            var environment = new Dictionary<string, string> { ["CODEX_HOME"] = codexHome, ["TRAEX_SESSIONS_DIR"] = traeDir };
            var rows = new TokenTracker(home, () => Now, environment: key => environment.GetValueOrDefault(key)).Sample();
            TokenReading? Row(string id) => rows.FirstOrDefault(row => row.SessionID == id);
            check(Running(Row("codex-moved"), "exec") && Row("codex-moved") is { ClientName: null, RateLimit.UsedPercent: 42, Model: "gpt-fixture", Project: "RolloutProject" }
                  && Running(Row("codex-default"), "exec"),
                  "Codex: a rollout under CODEX_HOME or the ~/.codex fallback was not read as a running tool turn");
            check(new[] { Row("trae-default"), Row("trae-moved") }.All(row => Running(row, "exec")
                      && row is { Source: TokenSource.Codex, ClientTitle: "TRAE CLI", RateLimit: null, CurrentTurnOutputTokens: 10 } && Resume(row) is null)
                  && Resume(Row("codex-default")) is not null && !Leaks(rows),
                  "TRAE CLI: a Codex-format rollout under ~/.trae/cli/sessions or TRAEX_SESSIONS_DIR was not read and labelled TRAE CLI, or kept Codex's usage limit or resume command");
        }
        catch (Exception error)
        {
            check(false, "Codex roots fixture error: " + error.Message);
        }
    }

    static void ClaudeRoots(string root, Action<bool, string> check)
    {
        try
        {
            // Claude Code: CLAUDE_CONFIG_DIR (a comma list), XDG_CONFIG_HOME\claude and ~\.claude; set-aside transcripts are skipped.
            var home = Path.Combine(root, "claude-home");
            var work = Path.Combine(root, "elsewhere", "claude-work");
            var team = Path.Combine(root, "elsewhere", "claude-team");
            var xdg = Path.Combine(root, "elsewhere", "xdg");
            Transcript(Path.Combine(work, "projects", "-tmp-a", "work.jsonl"), "claude-work");
            Transcript(Path.Combine(team, "projects", "-tmp-a", "team.jsonl"), "claude-team");
            Transcript(Path.Combine(xdg, "claude", "projects", "-tmp-a", "xdg.jsonl"), "claude-xdg");
            var project = Path.Combine(home, ".claude", "projects", "-tmp-a");
            Transcript(Path.Combine(project, "default.jsonl"), "claude-default");
            var orphan = Path.Combine(project, "default.orphaned-1791100000000-x1.jsonl");
            Transcript(orphan, "claude-orphan");
            // OpenClaude in ~\.openclaude and OPENCLAUDE_CONFIG_DIR; Qoder in ~\.qoder and flat in its IDE's SharedClientCache.
            var openClaude = Path.Combine(root, "elsewhere", "openclaude");
            Transcript(Path.Combine(home, ".openclaude", "projects", "-tmp-a", "oc.jsonl"), "openclaude-default");
            Transcript(Path.Combine(openClaude, "projects", "-tmp-a", "oc.jsonl"), "openclaude-moved");
            Transcript(Path.Combine(home, ".qoder", "projects", "-tmp-a", "q.jsonl"), "qoder-cli");
            Transcript(Path.Combine(home, "AppData", "Roaming", "Qoder", "SharedClientCache", "cli", "projects", "q.jsonl"), "qoder-ide");
            var environment = new Dictionary<string, string>
            {
                ["CLAUDE_CONFIG_DIR"] = $"{work}, {team}", ["XDG_CONFIG_HOME"] = xdg, ["OPENCLAUDE_CONFIG_DIR"] = openClaude,
            };
            var tracker = new TokenTracker(home, () => Now, environment: key => environment.GetValueOrDefault(key));
            var rows = tracker.Sample();
            TokenReading? Row(string id) => rows.FirstOrDefault(row => row.SessionID == id);
            check(new[] { "claude-work", "claude-team", "claude-xdg", "claude-default" }.All(id => Running(Row(id), "Bash")
                      && Row(id) is { ClientName: null, CurrentTurnOutputTokens: 30, Model: "claude-fixture", Project: "ClaudeProject" }),
                  "Claude Code: CLAUDE_CONFIG_DIR (a comma list), $XDG_CONFIG_HOME/claude or ~/.claude projects were not all read");
            check(Row("claude-orphan") is null && !tracker.IsLog(orphan) && tracker.IsLog(Path.Combine(project, "default.jsonl")),
                  "Claude Code: a set-aside .orphaned- transcript was listed or taken as a log");
            var clones = new Dictionary<string, string>
            {
                ["openclaude-default"] = "OpenClaude", ["openclaude-moved"] = "OpenClaude", ["qoder-cli"] = "Qoder", ["qoder-ide"] = "Qoder",
            };
            check(clones.All(pair => Running(Row(pair.Key), "Bash") && Row(pair.Key) is { Source: TokenSource.Claude, CurrentTurnOutputTokens: 30, Project: "ClaudeProject" } clone
                      && clone.ClientTitle == pair.Value && Resume(clone) is null)
                  && Resume(Row("claude-default")) is not null && !Leaks(rows),
                  "OpenClaude/Qoder: a Claude-format transcript in their folders was not read and labelled, or offered Claude Code's resume command");
        }
        catch (Exception error)
        {
            check(false, "Claude roots fixture error: " + error.Message);
        }
    }

    static void DroidRoots(string root, Action<bool, string> check)
    {
        try
        {
            // Factory Droid with FACTORY_HOME_OVERRIDE.
            var home = Path.Combine(root, "sandbox-home");
            Directory.CreateDirectory(home);
            var factory = Path.Combine(root, "elsewhere", "factory");
            var droidLog = Path.Combine(factory, ".factory", "sessions", "-tmp-a", "droid.jsonl");
            Write(droidLog, N("""{"type":"session_start","id":"droid"}"""));
            var tracker = new TokenTracker(home, () => Now, environment: key => key == "FACTORY_HOME_OVERRIDE" ? factory : null);
            check(tracker.DetectedSources().Contains(TokenSource.Droid) && tracker.IsLog(droidLog),
                  "Droid: sessions under FACTORY_HOME_OVERRIDE were not detected or taken as logs");
        }
        catch (Exception error)
        {
            check(false, "Gemini/Droid roots fixture error: " + error.Message);
        }
    }

    static void ClineRoots(string root, Action<bool, string> check)
    {
        try
        {
            // Cline's shared task store (~\.cline\data\tasks, CLINE_DATA_DIR) and Cline-format extensions in any editor folder.
            var home = Path.Combine(root, "cline-home");
            var data = Path.Combine(root, "elsewhere", "cline-data");
            var appData = Path.Combine(home, "AppData", "Roaming");
            JsonNode Say(double seconds, string kind, string text = "PRIVATE_TEXT") =>
                new JsonObject { ["ts"] = Ms(seconds), ["type"] = "say", ["say"] = kind, ["text"] = text };
            void Task(string folder)
            {
                Directory.CreateDirectory(folder);
                File.WriteAllText(Path.Combine(folder, "ui_messages.json"), new JsonArray
                {
                    Say(1, "text"),
                    Say(2, "api_req_started", """{"request":"PRIVATE_REQUEST","tokensIn":10,"tokensOut":25}"""),
                    Say(3, "tool", """{"tool":"readFile","path":"PRIVATE_PATH"}"""),
                    Say(4, "api_req_started", "{}"),
                }.ToJsonString());
            }
            Task(Path.Combine(home, ".cline", "data", "tasks", "shared-task"));
            Task(Path.Combine(data, "tasks", "moved-task"));
            Task(Path.Combine(appData, "Antigravity", "User", "globalStorage", "zoocodeorganization.zoo-code", "tasks", "zoo-task"));
            Task(Path.Combine(appData, "IBM Bob", "User", "globalStorage", "ibm.bob-code", "tasks", "bob-task"));
            Task(Path.Combine(appData, "Kiro", "User", "globalStorage", "saoudrizwan.claude-dev", "tasks", "kiro-task"));
            var sessions = Path.Combine(root, "elsewhere", "cline-sessions");
            Directory.CreateDirectory(sessions);
            var environment = new Dictionary<string, string> { ["CLINE_DATA_DIR"] = data, ["CLINE_SESSION_DATA_DIR"] = sessions };
            var rows = new TokenTracker(home, () => Now, environment: key => environment.GetValueOrDefault(key)).Sample();
            TokenReading? Row(string id) => rows.FirstOrDefault(row => row.SessionID == id);
            var names = new Dictionary<string, string>
            {
                ["shared-task"] = "Cline", ["moved-task"] = "Cline", ["kiro-task"] = "Cline", ["zoo-task"] = "Zoo Code", ["bob-task"] = "IBM Bob",
            };
            var clineProvider = TokenProvider.All.First(provider => provider.Source == TokenSource.Cline);
            check(names.All(pair => Row(pair.Key) is { Source: TokenSource.Cline, Active: true, CurrentTurnOutputTokens: 25 } row && row.ClientTitle == pair.Value)
                  && clineProvider.ExistingRoots(home, key => key == "CLINE_SESSION_DATA_DIR" ? sessions : null).Contains(sessions)
                  && !Leaks(rows),
                  "Cline: a task in ~/.cline/data/tasks, CLINE_DATA_DIR, CLINE_SESSION_DATA_DIR or another editor's Zoo Code/IBM Bob/Cline folder was not read or labelled");
        }
        catch (Exception error)
        {
            check(false, "Cline roots fixture error: " + error.Message);
        }
    }

    static void OmpRoots(string root, Action<bool, string> check)
    {
        try
        {
            // omp: named profiles and PI_CONFIG_DIR; Pi: PI_CODING_AGENT_SESSION_DIR. omp's XDG layout is mac/Linux only.
            var home = Path.Combine(root, "omp-home");
            var piSessions = Path.Combine(root, "elsewhere", "pi-sessions");
            void Session(string folder, string id) =>
                Write(Path.Combine(folder, "--tmp-Fixture-OmpProject--", $"2026-10-04T04-00-00-000Z_{id}.jsonl"),
                    new JsonObject { ["type"] = "session", ["version"] = 3, ["id"] = id, ["timestamp"] = Iso(0), ["cwd"] = "/tmp/Fixture/OmpProject" },
                    new JsonObject { ["type"] = "message", ["id"] = id + "-u", ["timestamp"] = Iso(1),
                                     ["message"] = new JsonObject { ["role"] = "user", ["content"] = "PRIVATE_PROMPT", ["timestamp"] = Ms(1) } },
                    new JsonObject { ["type"] = "message", ["id"] = id + "-a", ["timestamp"] = Iso(3), ["message"] = new JsonObject
                    {
                        ["role"] = "assistant", ["model"] = "omp-model", ["provider"] = "fixture", ["stopReason"] = "toolUse", ["timestamp"] = Ms(2),
                        ["usage"] = N("""{"input":10,"output":40}"""),
                        ["content"] = new JsonArray { new JsonObject { ["type"] = "toolCall", ["id"] = id + "-c", ["name"] = "bash", ["arguments"] = N("""{"command":"PRIVATE_CMD"}""") } },
                    } });
            Session(Path.Combine(home, ".omp", "profiles", "work", "agent", "sessions"), "omp-profile");
            Session(Path.Combine(home, ".ompx", "agent", "sessions"), "omp-config");
            Session(Path.Combine(home, ".ompx", "profiles", "team", "agent", "sessions"), "omp-config-profile");
            Session(piSessions, "pi-moved");
            var environment = new Dictionary<string, string> { ["PI_CONFIG_DIR"] = ".ompx", ["PI_CODING_AGENT_SESSION_DIR"] = piSessions };
            var rows = new TokenTracker(home, () => Now, environment: key => environment.GetValueOrDefault(key)).Sample();
            TokenReading? Row(string id) => rows.FirstOrDefault(row => row.SessionID == id);
            check(new[] { "omp-profile", "omp-config", "omp-config-profile" }.All(id => Running(Row(id), "bash")
                      && Row(id) is { ClientTitle: "omp", CurrentTurnOutputTokens: 40 })
                  && Running(Row("pi-moved"), "bash") && Row("pi-moved")?.ClientTitle == "Pi" && !Leaks(rows),
                  "omp/Pi: a session in a named profile, PI_CONFIG_DIR, $XDG_DATA_HOME/omp or PI_CODING_AGENT_SESSION_DIR was not read or was mislabelled");
        }
        catch (Exception error)
        {
            check(false, "omp roots fixture error: " + error.Message);
        }
    }
}
