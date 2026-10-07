using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TokenCat;

/// CursorChecks.swift: Cursor fixture checks, run inside `TrackerChecks.Run`, descriptions verbatim. Synthetic metadata
/// only, temp homes; text fields hold "PRIVATE".
public static class CursorChecks
{
    static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-04T12:00:00Z", CultureInfo.InvariantCulture);
    static long Ms(double seconds) => Start.AddSeconds(seconds).ToUnixTimeMilliseconds();
    static string J(object value) => JsonSerializer.Serialize(value);
    static byte[] Lines(params object[] records) => Encoding.UTF8.GetBytes(string.Concat(records.Select(record => J(record) + "\n")));

    static void Write(string path, byte[] data, double modified)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, data);
        File.SetLastWriteTimeUtc(path, Start.AddSeconds(modified).UtcDateTime);
    }

    static void Append(string path, byte[] data, double modified)
    {
        using (var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) stream.Write(data);
        File.SetLastWriteTimeUtc(path, Start.AddSeconds(modified).UtcDateTime);
    }

    /// Writes a database the way Cursor leaves it once it quit: WAL mode, with no `-wal` or `-shm` beside it (Apple's SQLite
    /// keeps an empty WAL after the last connection; Cursor's removes it).
    static bool Database(string path, bool wal, params (string Sql, object?[] Values)[] statements)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var written = false;
        using (var database = OpenCodeDatabase.Open(path, create: true))
        {
            if (database is not null && (!wal || database.Query("PRAGMA journal_mode=WAL", [], _ => { })))
                written = statements.All(statement => database.Query(statement.Sql, statement.Values, _ => { }));
        }
        foreach (var suffix in new[] { "-wal", "-shm" }) File.Delete(path + suffix);
        return written;
    }

    /// The `projects\<slug>` name Cursor gives a folder: every character but an ASCII letter or digit becomes `-`.
    static string Slug(string path) => new string([.. path.Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-')]).TrimStart('-');

    /// The temp folder with its long names (a Windows TEMP may be spelled with 8.3 short names, which no slug holds).
    static string LongPath(string path)
    {
        var full = Path.GetFullPath(path);
        var current = Path.GetPathRoot(full)!;
        foreach (var part in full[current.Length..].Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries))
            current = Path.Combine(current, new DirectoryInfo(current).EnumerateFileSystemInfos(part).FirstOrDefault()?.Name ?? part);
        return current;
    }

    static object User(string text = "<user_query>PRIVATE_PROMPT</user_query>") =>
        new { role = "user", message = new { content = new[] { new { type = "text", text } } } };

    static object Assistant(params string[] tools) =>
        new
        {
            role = "assistant",
            message = new { content = new object[] { new { type = "text", text = "PRIVATE_REPLY" } }
                .Concat(tools.Select(name => (object)new { type = "tool_use", name, input = new { command = "PRIVATE_INPUT" } })).ToArray() },
        };

    static object Ended(string status) =>
        status == "success" ? new { type = "turn_ended", status } : new { type = "turn_ended", status, error = "PRIVATE_ERROR" };

    public static void Run(Action<bool, string> check)
    {
        check(CursorLog.PromptTime("<timestamp>Friday, Jul 17, 2026, 12:26 AM (UTC+9)</timestamp>\n<user_query>x</user_query>")
                == DateTimeOffset.Parse("2026-07-16T15:26:00Z", CultureInfo.InvariantCulture)
              && CursorLog.PromptTime("<timestamp>Monday, Oct 5, 2026, 9:05 PM (UTC-5:30)</timestamp>")
                == DateTimeOffset.Parse("2026-10-06T02:35:00Z", CultureInfo.InvariantCulture)
              && CursorLog.PromptTime("<timestamp>Friday, Jul 17, 2026, 12:26 AM (UTC)</timestamp>")
                == DateTimeOffset.Parse("2026-07-17T00:26:00Z", CultureInfo.InvariantCulture)
              && CursorLog.PromptTime("<user_query><timestamp>Friday, Jul 17, 2026, 12:26 AM (UTC+9)</timestamp></user_query>") is null
              && CursorLog.PromptTime("<timestamp>yesterday (UTC+9)</timestamp>") is null,
              "Cursor: a prompt's <timestamp> tag was misread, or a tag not leading the prompt was read");
        var root = LongPath(Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), $"TokenCat-cursor-{Guid.NewGuid()}")).FullName);
        try
        {
            var home = Path.Combine(root, "home");
            var projects = Path.Combine(home, ".cursor", "projects");
            // The workspace a slug stands for, beside a decoy that matches only its first word.
            var workspace = Path.Combine(root, "Work Space", "my_app.v2");
            Directory.CreateDirectory(workspace);
            Directory.CreateDirectory(Path.Combine(root, "Work"));
            var transcripts = Path.Combine(projects, Slug(workspace), "agent-transcripts");
            var main = Path.Combine(transcripts, "cur-main", "cur-main.jsonl");
            Write(main, Lines(User("<timestamp>Sunday, Oct 4, 2026, 9:00 PM (UTC+9)</timestamp>\n<user_query>PRIVATE_PROMPT</user_query>"),
                              Assistant("Shell")), 10);
            var sub = Path.Combine(transcripts, "cur-main", "subagents", "cur-sub.jsonl");
            Write(sub, Lines(User(), Assistant("Read")), 8);
            var failed = Path.Combine(transcripts, "cur-error.jsonl");
            Write(failed, Lines(User(), Assistant("Grep"), Ended("error")), 5);
            var legacy = Path.Combine(transcripts, "cur-legacy.txt");
            Write(legacy, Encoding.UTF8.GetBytes("user:\nPRIVATE_PROMPT\n\nassistant:\nPRIVATE_REPLY\n[Tool call] Read\n  path: PRIVATE_PATH\n"), 10);
            var ide = Path.Combine(projects, "Users-nobody-tokencat-fixture", "agent-transcripts", "cur-ide", "cur-ide.jsonl");
            Write(ide, Lines(User(), Assistant("Shell")), 10);
            var empty = Path.Combine(projects, "empty-window", "agent-transcripts", "cur-empty", "cur-empty.jsonl");
            Write(empty, Lines(User(), Assistant(), Ended("success")), 4);
            var gone = Path.Combine(projects, Slug(Path.Combine(root, "gone dir")), "agent-transcripts", "cur-gone.jsonl");
            Write(gone, Lines(User(), Assistant(), Ended("success")), 3);
            // Folders Cursor recorded resolve a slug without opening any folder: the CLI's state file and the IDE's workspaces.
            var cliFolder = Path.Combine(home, "Code", "agent app");
            var separator = Path.DirectorySeparatorChar;
            Write(Path.Combine(home, ".cursor", "agent-cli-state.json"),
                  Encoding.UTF8.GetBytes(J(new { version = 1, workerIdsByDisplayName = new Dictionary<string, string> { [$"~{separator}Code{separator}agent app @ PRIVATE_HOST"] = "w-1" } })), 0);
            Write(Path.Combine(projects, Slug(cliFolder), "agent-transcripts", "cur-cli", "cur-cli.jsonl"), Lines(User(), Assistant(), Ended("success")), 2);
            Write(Path.Combine(projects, "tmp-CursorIDEProject", "agent-transcripts", "cur-ws", "cur-ws.jsonl"), Lines(User(), Assistant(), Ended("success")), 2);
            // The cursor-agent CLI's chat store names the model of a session the IDE does not know.
            var meta = J(new { agentId = "cur-main", name = "PRIVATE_NAME", lastUsedModel = "gpt-5.1-codex", blobEncryptionKey = "PRIVATE_KEY" });
            var hex = Convert.ToHexStringLower(Encoding.UTF8.GetBytes(meta));
            var state = Path.Combine(home, "AppData", "Roaming", "Cursor", "User", "globalStorage", "state.vscdb");
            string Header(string id, bool pending) =>
                J(new
                {
                    composerId = id, name = "Fix login redirect", hasBlockingPendingActions = pending, contextUsagePercent = 25,
                    workspaceIdentifier = new { id = "w1", uri = new { fsPath = "/tmp/CursorIDEProject", scheme = "file" } },
                    lastUpdatedAt = Ms(11), subtitle = "PRIVATE_SUBTITLE",
                });
            if (!Database(Path.Combine(home, ".cursor", "chats", "0123abcd", "cur-main", "store.db"), false,
                    ("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)", []), ("INSERT INTO meta VALUES ('0', ?)", [hex]),
                    ("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)", []))
                || !Database(state, true,
                    ("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", []),
                    ("CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", []),
                    ("CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, "
                        + "isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT)", []),
                    ($"INSERT INTO composerHeaders (composerId, lastUpdatedAt, isSubagent, value) VALUES ('cur-ide', {Ms(11)}, 0, ?)",
                     [Header("cur-ide", pending: true)]),
                    ($"INSERT INTO composerHeaders (composerId, lastUpdatedAt, isSubagent, value, subagentTypeName) VALUES ('cur-sub', {Ms(8)}, 1, ?, 'explore')",
                     [J(new { composerId = "cur-sub", lastUpdatedAt = Ms(8) })]),
                    ($"INSERT INTO composerHeaders (composerId, lastUpdatedAt, isSubagent, value) VALUES ('cur-error', {Ms(5)}, 0, ?)",
                     [J(new { composerId = "cur-error", workspaceIdentifier = new { uri = new { fsPath = "/tmp/CursorIDEProject" } }, lastUpdatedAt = Ms(5) })]),
                    ("INSERT INTO cursorDiskKV VALUES ('composerData:cur-ide', ?)",
                     [J(new
                     {
                         composerId = "cur-ide", text = "PRIVATE_DRAFT", modelConfig = new { modelName = "default" }, contextTokensUsed = 50_000,
                         contextTokenLimit = 200_000, lastUpdatedAt = Ms(11),
                         fullConversationHeadersOnly = new[] { new { bubbleId = "b1", type = 1 }, new { bubbleId = "b2", type = 2 } },
                     })]),
                    ("INSERT INTO cursorDiskKV VALUES ('bubbleId:cur-ide:b1', ?)",
                     [J(new { type = 1, text = "PRIVATE_PROMPT", modelInfo = new { modelName = "claude-4.5-sonnet" } })]),
                    ("INSERT INTO cursorDiskKV VALUES ('bubbleId:cur-ide:b2', ?)", [J(new { type = 2, text = "PRIVATE_REPLY", modelInfo = new { modelName = "other" } })]),
                    ("INSERT INTO cursorDiskKV VALUES ('composerData:cur-error', ?)",
                     [J(new { composerId = "cur-error", modelConfig = new { modelName = "gpt-5" }, gitWorktree = new { worktreePath = "/tmp/CursorWorktree" }, lastUpdatedAt = Ms(5) })])))
            {
                check(false, "Cursor fixture: databases not written");
                return;
            }
            // macOS SQLite refuses a read-only connection to a WAL database without its -wal, which is why the reader opens a
            // snapshot; on Windows the fixture's -wal may outlive its writer and winsqlite3 may open it, so the precondition
            // only holds off Windows.
            using (var plain = OpenCodeDatabase.Open(state))
                check(OperatingSystem.IsWindows()
                      || (!File.Exists(state + "-wal") && plain?.Query("SELECT 1 FROM composerHeaders", [], _ => { }) != true),
                      "Cursor fixture: the IDE database read without its WAL as a plain read-only connection, so the snapshot path goes untested");

            var now = Start.AddSeconds(12);
            var tracker = new TokenTracker(home, () => now, environment: _ => null);
            var rows = tracker.Sample();
            TokenReading? Row(string session) => rows.FirstOrDefault(r => r.Source == TokenSource.Cursor && r.SessionID == session);
            var open = Row("cur-main");
            check(open?.ActivityState == TokenActivityState.Tool && open.Active && open.ToolName == "Shell" && open.ToolCategory == ToolCategory.Command
                  && open.CurrentTurnStartedAt == Start && open.CurrentTurnOutputTokens is null && open.LastActivity == Start.AddSeconds(10),
                  "Cursor: an open turn with a tool use was not a live tool turn dated by its prompt's timestamp tag, or counted output");
            check(open?.Project == "my_app.v2" && open.ProjectPath == workspace && open.Title is null && open.Model == "gpt-5.1-codex" && !open.IsSubagent,
                  "Cursor: the project slug was not matched to its existing folder, or the CLI store's model was missed");
            var child = Row("cur-sub");
            check(child?.IsSubagent == true && child.ParentSessionID == "cur-main" && child.AgentID == "cur-sub" && child.AgentRole == "explore"
                  && child.ActivityState == TokenActivityState.Tool && child.ToolName == "Read" && child.ToolCategory == ToolCategory.File
                  && child.Project == "my_app.v2",
                  "Cursor: a subagent transcript was not grouped under its parent with its type, tool and project");
            var error = Row("cur-error");
            check(error?.ActivityState == TokenActivityState.Interrupted && !error.Active && error.ToolName is null
                  && error.Project == "CursorWorktree" && error.ProjectPath == "/tmp/CursorWorktree" && error.Model == "gpt-5" && error.Title is null,
                  "Cursor: a turn ended with an error was not interrupted, or the composer's worktree did not win over its workspace");
            var ideRow = Row("cur-ide");
            check(ideRow?.ActivityState == TokenActivityState.Input && ideRow.Active && ideRow.ToolName == "Shell" && ideRow.Title == "Fix login redirect"
                  && ideRow.Model == "claude-4.5-sonnet" && ideRow.Project == "CursorIDEProject" && ideRow.ProjectPath == "/tmp/CursorIDEProject"
                  && ideRow.Context?.UsedTokens == 50_000 && ideRow.Context.WindowTokens == 200_000
                  && ideRow.Context.RecordedAt == Start.AddSeconds(11) && ideRow.LastLogAt == Start.AddSeconds(11),
                  "Cursor: the IDE database's title, pending action, workspace, latest request model or context was not read");
            check(Row("cur-empty")?.Project == "empty-window" && Row("cur-empty")?.ProjectPath is null
                  && Row("cur-empty")?.ActivityState == TokenActivityState.Complete
                  && Row("cur-gone")?.Project == "gone-dir" && Row("cur-gone")?.ProjectPath is null,
                  "Cursor: a slug without a folder was not shown as is, or a deleted folder lost its own name");
            check(Row("cur-cli")?.Project == "agent app" && Row("cur-cli")?.ProjectPath == cliFolder
                  && Row("cur-ws")?.Project == "CursorIDEProject" && Row("cur-ws")?.ProjectPath == "/tmp/CursorIDEProject",
                  "Cursor: a slug was not matched to a folder the CLI state or an IDE composer recorded");
            check(Row("cur-legacy")?.ActivityState == TokenActivityState.Tool && Row("cur-legacy")?.ToolName == "Read",
                  "Cursor: a legacy text transcript's open tool call was not shown");

            // The step after the tool, then the end of the turn; the approval is granted in the IDE.
            Append(main, Lines(Assistant()), 20);
            Append(legacy, Encoding.UTF8.GetBytes("[Tool result]\n  PRIVATE_RESULT\nPRIVATE_ANSWER\n"), 20);
            if (!Database(state, true, ("UPDATE composerHeaders SET value = ? WHERE composerId = 'cur-ide'", [Header("cur-ide", pending: false)])))
            {
                check(false, "Cursor fixture: the IDE database was not updated");
                return;
            }
            now = Start.AddSeconds(21);
            rows = tracker.Sample();
            check(Row("cur-main")?.ActivityState == TokenActivityState.Working && Row("cur-main")?.ToolName is null
                  && Row("cur-main")?.LastActivity == Start.AddSeconds(20)
                  && Row("cur-ide")?.ActivityState == TokenActivityState.Tool && Row("cur-legacy")?.ActivityState == TokenActivityState.Complete,
                  "Cursor: a later step did not end the tool run, a granted approval stayed input, or legacy answer text did not complete the turn");
            Append(main, Lines(Ended("success")), 30);
            now = Start.AddSeconds(31);
            rows = tracker.Sample();
            var done = Row("cur-main");
            check(done?.ActivityState == TokenActivityState.Complete && !done.Active && done.CurrentTurnStartedAt is null && done.LastOutputTokens is null
                  && done.LastActivity == Start.AddSeconds(30),
                  "Cursor: turn_ended success did not complete the turn at the transcript's write time");
            var cursorRows = rows.Where(r => r.Source == TokenSource.Cursor).ToList();
            var encoded = Encoding.UTF8.GetString(Json.Serialize(cursorRows));
            check(cursorRows.Count == 9 && !encoded.Contains("PRIVATE", StringComparison.Ordinal),
                  "Cursor: a transcript was not listed, or prompt, reply, tool input or store text leaked into a reading");
            check(tracker.IsLog(main) && tracker.IsLog(sub) && tracker.IsLog(failed) && tracker.IsLog(legacy)
                  && !tracker.IsLog(Path.Combine(transcripts, "cur-main", "notes.jsonl"))
                  && !tracker.IsLog(Path.Combine(transcripts, "cur-main", "subagents", "notes.txt"))
                  && !tracker.IsLog(Path.Combine(projects, "empty-window", "terminals", "1.txt")),
                  "Cursor: a changed path was matched to the wrong file of a project folder");

            // Older IDE builds keep the headers as one JSON value in ItemTable.
            var oldHome = Path.Combine(root, "old-home");
            Write(Path.Combine(oldHome, ".cursor", "projects", "Users-nobody-old", "agent-transcripts", "cur-old", "cur-old.jsonl"),
                  Lines(User(), Assistant(), Ended("success")), 5);
            if (!Database(Path.Combine(oldHome, "AppData", "Roaming", "Cursor", "User", "globalStorage", "state.vscdb"), true,
                    ("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", []),
                    ("INSERT INTO ItemTable VALUES ('composer.composerHeaders', ?)", [J(new
                    {
                        allComposers = new[]
                        {
                            new { composerId = "cur-old", name = "Old fixture title", lastUpdatedAt = Ms(5),
                                  workspaceIdentifier = new { uri = new { fsPath = "/tmp/CursorOldProject" } } },
                        },
                    })])))
            {
                check(false, "Cursor fixture: the legacy IDE database was not written");
                return;
            }
            var old = new TokenTracker(oldHome, () => now, environment: _ => null).Sample().FirstOrDefault(r => r.SessionID == "cur-old");
            check(old?.Title == "Old fixture title" && old.Project == "CursorOldProject" && old.ActivityState == TokenActivityState.Complete,
                  "Cursor: composer headers kept in ItemTable (older builds) were not read");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            check(false, $"Cursor fixtures could not be written: {error}");
        }
        finally
        {
            try { Directory.Delete(root, true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}
