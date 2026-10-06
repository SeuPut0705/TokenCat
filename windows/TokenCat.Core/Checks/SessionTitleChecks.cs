using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenCat;

/// SessionTitleChecks.swift: `SessionTitle.Clean`, and per client a fixture that produces a title, a rename that replaces it
/// and a session without one (Claude Code, Codex, omp, Pi, Gemini CLI, Qwen Code; OpenCode, Copilot CLI, Amp and Droid are
/// covered beside their other fixtures). Synthetic metadata only, temp homes. Run from `TrackerChecks.Run`; descriptions verbatim.
public static class SessionTitleChecks
{
    static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-04T05:00:00Z", CultureInfo.InvariantCulture);
    static string At(double seconds) => Start.AddSeconds(seconds).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    static JsonObject N(string json) => JsonNode.Parse(json)!.AsObject();
    static int Length(string? text) => text is null ? -1 : new StringInfo(text).LengthInTextElements;

    static void Append(string path, IEnumerable<JsonNode> records)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        stream.Write(Encoding.UTF8.GetBytes(string.Concat(records.Select(record => record.ToJsonString() + "\n"))));
    }

    public static void Run(Action<bool, string> check)
    {
        // Sanitising: one line, collapsed space, no invisible reordering, at most 80 characters ending in "…".
        var longTitle = string.Concat(Enumerable.Repeat("abcdefghij ", 12));
        var cut = SessionTitle.Clean(longTitle);
        check(SessionTitle.Clean("  Fix\tthe\n\nlogin \u0007bug\r\n ") == "Fix the login bug"
              && SessionTitle.Clean("a\u202Eb\u2066c\uFEFFd") == "abcd"
              && SessionTitle.Clean("👩‍💻 Pair session") == "👩‍💻 Pair session"
              && Length(cut) == SessionTitle.MaximumLength && cut!.EndsWith('…') && !cut.EndsWith(" …", StringComparison.Ordinal)
              && SessionTitle.Clean(new string('가', 80)) == new string('가', 80)
              && SessionTitle.Clean(" \n\t ") is null && SessionTitle.Clean("") is null
              && SessionTitle.Clean(JsonDocument.Parse("42").RootElement) is null
              && Length(SessionTitle.Clean(new string('x', 100_000))) == SessionTitle.MaximumLength,
              "Session title: control characters, line breaks, bidi overrides or the 80-character cap were not handled");

        var root = Path.Combine(Path.GetTempPath(), $"tokencat-titles-{Guid.NewGuid()}");
        var now = Start.AddSeconds(120);
        try
        {
            // Claude Code: a rename outranks the generated title whichever came last; a newer rename replaces it.
            var claudeHome = Path.Combine(root, "claude");
            var claudeFolder = Path.Combine(claudeHome, ".claude", "projects", "-tmp-ClaudeProject");
            JsonNode[] ClaudeTurn(string session, double seconds) =>
            [
                new JsonObject
                {
                    ["type"] = "user", ["uuid"] = $"{session}-u{seconds}", ["timestamp"] = At(seconds), ["sessionId"] = session, ["cwd"] = "/tmp/ClaudeProject",
                    ["message"] = N("""{"role":"user","content":[{"type":"text","text":"PRIVATE_PROMPT"}]}"""),
                },
                new JsonObject
                {
                    ["type"] = "assistant", ["uuid"] = $"{session}-a{seconds}", ["timestamp"] = At(seconds + 1), ["sessionId"] = session,
                    ["message"] = new JsonObject
                    {
                        ["id"] = $"{session}-m{seconds}", ["model"] = "claude-fixture", ["stop_reason"] = "end_turn",
                        ["usage"] = N("""{"output_tokens":5,"input_tokens":10}"""), ["content"] = new JsonArray(N("""{"type":"text","text":"PRIVATE_REPLY"}""")),
                    },
                },
            ];
            var claudeLog = Path.Combine(claudeFolder, "c-1.jsonl");
            Append(claudeLog, [.. ClaudeTurn("c-1", 0), N("""{"type":"ai-title","aiTitle":"Generated Claude title","sessionId":"c-1"}""")]);
            Append(Path.Combine(claudeFolder, "c-2.jsonl"), ClaudeTurn("c-2", 0));
            var claude = new TokenTracker(claudeHome, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            TokenReading? ClaudeRow(string session) => claude.Sample().FirstOrDefault(r => r.SessionID == session);
            var generated = ClaudeRow("c-1")?.Title;
            Append(claudeLog, [N("""{"type":"custom-title","customTitle":"Renamed\nClaude session","sessionId":"c-1"}""")]);
            var renamed = ClaudeRow("c-1")?.Title;
            Append(claudeLog, [.. ClaudeTurn("c-1", 5), N("""{"type":"ai-title","aiTitle":"Regenerated title","sessionId":"c-1"}""")]);
            var afterRegeneration = ClaudeRow("c-1")?.Title;
            Append(claudeLog, [N("""{"type":"custom-title","customTitle":"Second rename","sessionId":"c-1"}""")]);
            check(generated == "Generated Claude title" && renamed == "Renamed Claude session"
                  && afterRegeneration == "Renamed Claude session" && ClaudeRow("c-1")?.Title == "Second rename"
                  && ClaudeRow("c-2") is { Title: null },
                  "Claude Code: ai-title, a custom-title rename outranking it, a later rename, or a session without a title went wrong");
            // A title record only in the head of a long log is found by the bounded header scan.
            Append(Path.Combine(claudeFolder, "c-3.jsonl"), [N("""{"type":"summary","summary":"Older summary title","leafUuid":"x"}"""), .. ClaudeTurn("c-3", 0),
                .. Enumerable.Range(1, 40).SelectMany(second => ClaudeTurn("c-3", second))]);
            var tailOnly = new TokenTracker(claudeHome, () => now, initialTailBytes: 2_048, environment: _ => null);
            check(tailOnly.Sample().FirstOrDefault(r => r.SessionID == "c-3")?.Title == "Older summary title",
                  "Claude Code: a summary title in the log's head was lost when the first read started mid-file");

            // Codex: names come from session_index.jsonl beside sessions/; the newest non-empty one per thread wins.
            var codexHome = Path.Combine(root, "codex");
            var codexFolder = Path.Combine(codexHome, ".codex", "sessions", "2026", "10", "04");
            const string named = "019f0000-0000-7000-8000-00000000c0de", unnamed = "019f0000-0000-7000-8000-00000000beef";
            JsonNode[] Rollout(string id) =>
            [
                new JsonObject { ["type"] = "session_meta", ["timestamp"] = At(0), ["payload"] = new JsonObject { ["id"] = id, ["cwd"] = "/tmp/CodexProject", ["timestamp"] = At(0) } },
                new JsonObject { ["type"] = "turn_context", ["timestamp"] = At(0), ["payload"] = N("""{"model":"codex-fixture"}""") },
                new JsonObject { ["type"] = "event_msg", ["timestamp"] = At(1), ["payload"] = N("""{"type":"task_started","turn_id":"t1"}""") },
                new JsonObject
                {
                    ["type"] = "event_msg", ["timestamp"] = At(2),
                    ["payload"] = N("""{"type":"token_count","info":{"total_token_usage":{"output_tokens":7,"input_tokens":100},"last_token_usage":{"output_tokens":7,"input_tokens":100}}}"""),
                },
                new JsonObject { ["type"] = "event_msg", ["timestamp"] = At(3), ["payload"] = N("""{"type":"task_complete","turn_id":"t1","duration_ms":1000}""") },
            ];
            Append(Path.Combine(codexFolder, $"rollout-2026-10-04T05-00-00-{named}.jsonl"), Rollout(named));
            Append(Path.Combine(codexFolder, $"rollout-2026-10-04T05-00-00-{unnamed}.jsonl"), Rollout(unnamed));
            var index = Path.Combine(codexHome, ".codex", "session_index.jsonl");
            JsonNode Name(string id, string name, double seconds) => new JsonObject { ["id"] = id, ["thread_name"] = name, ["updated_at"] = At(seconds) };
            Append(index, [Name(named.ToUpperInvariant(), "Codex thread name", 3)]);
            var codex = new TokenTracker(codexHome, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            TokenReading? CodexRow(string id) => codex.Sample().FirstOrDefault(r => r.SessionID == id);
            var first = CodexRow(named)?.Title;
            Append(index, [Name(named, "Renamed Codex thread", 4), Name(named, "  ", 5)]);
            var renamedThread = CodexRow(named)?.Title;
            // A rewrite that removes a name (the index shrinks) is read again from the top.
            File.WriteAllText(index, Name(named, "Kept", 6).ToJsonString() + "\n");
            check(first == "Codex thread name" && renamedThread == "Renamed Codex thread" && CodexRow(named)?.Title == "Kept"
                  && CodexRow(unnamed) is { Title: null },
                  "Codex: a session_index thread name, its rename, a rewritten index or a thread without a name went wrong");

            // omp: the title slot and header, then title_change records; Pi: session_info names, an empty one clears.
            var ompHome = Path.Combine(root, "omp");
            var ompLog = Path.Combine(ompHome, ".omp", "agent", "sessions", "--tmp-OmpTitles--", "2026-10-04T05-00-00-000Z_omp-t.jsonl");
            JsonNode[] OmpTurn(double first = 1, double second = 2) =>
            [
                new JsonObject { ["type"] = "message", ["id"] = "m1", ["timestamp"] = At(first), ["message"] = N("""{"role":"user","content":"PRIVATE","timestamp":0}""") },
                new JsonObject
                {
                    ["type"] = "message", ["id"] = "m2", ["timestamp"] = At(second),
                    ["message"] = N("""{"role":"assistant","stopReason":"stop","usage":{"output":3},"content":[]}"""),
                },
            ];
            Append(ompLog, [new JsonObject { ["type"] = "title", ["v"] = 1, ["title"] = "Slot title", ["source"] = "auto", ["updatedAt"] = At(0) },
                new JsonObject { ["type"] = "session", ["version"] = 3, ["id"] = "omp-t", ["timestamp"] = At(0), ["cwd"] = "/tmp/OmpTitles", ["title"] = "Header title" },
                .. OmpTurn()]);
            var piLog = Path.Combine(ompHome, ".pi", "agent", "sessions", "--tmp-PiTitles--", "2026-10-04T05-00-00-000Z_pi-t.jsonl");
            Append(piLog, [new JsonObject { ["type"] = "session", ["version"] = 3, ["id"] = "pi-t", ["timestamp"] = At(0), ["cwd"] = "/tmp/PiTitles" }, .. OmpTurn()]);
            var omp = new TokenTracker(ompHome, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            TokenReading? OmpRow(string id) => omp.Sample().FirstOrDefault(r => r.SessionID == id);
            var slot = OmpRow("omp-t")?.Title;
            var piNone = OmpRow("pi-t");
            Append(ompLog, [new JsonObject { ["type"] = "title_change", ["id"] = "tc1", ["timestamp"] = At(3), ["title"] = "Renamed omp", ["source"] = "user" }]);
            Append(piLog, [new JsonObject { ["type"] = "session_info", ["id"] = "si1", ["timestamp"] = At(3), ["name"] = "Pi name" }]);
            var ompRenamed = OmpRow("omp-t")?.Title;
            var piNamed = OmpRow("pi-t")?.Title;
            Append(piLog, [new JsonObject { ["type"] = "session_info", ["id"] = "si2", ["timestamp"] = At(4), ["name"] = "" }]);
            check(slot == "Slot title" && ompRenamed == "Renamed omp" && piNone is { Title: null } && piNamed == "Pi name"
                  && OmpRow("pi-t") is { Title: null },
                  "omp/Pi: the title slot, a title_change rename, a Pi session_info name or its clearing went wrong");
            // A tail that starts mid-file keeps its newer title_change over the head's slot.
            Append(ompLog, Enumerable.Range(10, 51).SelectMany(second => OmpTurn(second, second)));
            var ompTail = new TokenTracker(ompHome, () => now, initialTailBytes: 1_024, environment: _ => null);
            Append(ompLog, [new JsonObject { ["type"] = "title_change", ["id"] = "tc2", ["timestamp"] = At(61), ["title"] = "Newest omp", ["source"] = "auto" }]);
            check(ompTail.Sample().FirstOrDefault(r => r.SessionID == "omp-t")?.Title == "Newest omp",
                  "omp: the head's title slot replaced a newer title_change read from the tail");

            // Gemini CLI: the generated summary in metadata or a $set; Qwen Code: custom_title records, newest first.
            var chatHome = Path.Combine(root, "chats");
            var geminiLog = Path.Combine(chatHome, ".gemini", "tmp", "proj", "chats", "session-2026-10-04T05-00-gt.jsonl");
            var geminiPlain = Path.Combine(chatHome, ".gemini", "tmp", "proj", "chats", "session-2026-10-04T05-00-gn.jsonl");
            JsonNode[] GeminiChat(string id, string? summary = null)
            {
                var meta = new JsonObject { ["sessionId"] = id, ["projectHash"] = "h", ["startTime"] = At(0), ["lastUpdated"] = At(0), ["kind"] = "main" };
                if (summary is not null) meta["summary"] = summary;
                return
                [
                    meta,
                    new JsonObject { ["id"] = $"{id}-u1", ["timestamp"] = At(1), ["type"] = "user", ["content"] = new JsonArray(N("""{"text":"PRIVATE"}""")) },
                    new JsonObject { ["id"] = $"{id}-g1", ["timestamp"] = At(2), ["type"] = "gemini", ["content"] = "PRIVATE", ["tokens"] = N("""{"output":4,"total":4}""") },
                ];
            }
            Append(geminiLog, GeminiChat("gem-t", summary: "Gemini summary"));
            Append(geminiPlain, GeminiChat("gem-n"));
            var qwenLog = Path.Combine(chatHome, ".qwen", "projects", "-tmp-QwenTitles", "chats", "qt-1.jsonl");
            JsonNode Qwen(string uuid, string type, double seconds, JsonObject extra)
            {
                var record = new JsonObject { ["uuid"] = uuid, ["sessionId"] = "qt-1", ["timestamp"] = At(seconds), ["type"] = type, ["cwd"] = "/tmp/QwenTitles" };
                foreach (var (key, value) in extra.ToList()) record[key] = value?.DeepClone();
                return record;
            }
            Append(qwenLog, [Qwen("q1", "user", 1, N("""{"message":{"role":"user","parts":[{"text":"PRIVATE"}]}}""")),
                Qwen("q2", "assistant", 2, N("""{"message":{"role":"model","parts":[{"text":"PRIVATE"}]}}"""))]);
            var chats = new TokenTracker(chatHome, () => now, discoveryIntervalSeconds: 0, environment: _ => null);
            TokenReading? ChatRow(string id) => chats.Sample().FirstOrDefault(r => r.SessionID == id);
            var geminiFirst = ChatRow("gem-t")?.Title;
            var qwenNone = ChatRow("qt-1");
            Append(geminiLog, [new JsonObject { ["$set"] = new JsonObject { ["summary"] = "Gemini resummarised", ["lastUpdated"] = At(5) } }]);
            Append(qwenLog, [
                Qwen("q3", "system", 3, N("""{"subtype":"custom_title","systemPayload":{"customTitle":"Qwen auto title","titleSource":"auto"}}""")),
                Qwen("q4", "system", 4, N("""{"subtype":"custom_title","systemPayload":{"customTitle":"Qwen renamed","titleSource":"manual"}}"""))]);
            check(geminiFirst == "Gemini summary" && ChatRow("gem-t")?.Title == "Gemini resummarised" && ChatRow("gem-n") is { Title: null }
                  && qwenNone is { Title: null } && ChatRow("qt-1")?.Title == "Qwen renamed",
                  "Gemini/Qwen: a metadata summary, its $set update, a chat without one, or Qwen's newest custom_title went wrong");
            var encoded = Encoding.UTF8.GetString(Json.Serialize(claude.Sample().Concat(omp.Sample()).Concat(chats.Sample()).ToList()));
            check(!encoded.Contains("PRIVATE", StringComparison.Ordinal), "Session titles: prompt or reply text leaked into a reading");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            check(false, $"Session title fixtures could not be written: {error.Message}");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}
