import Foundation
import SQLite3

/// Cursor fixture checks, run inside `runTrackerChecks`. Synthetic metadata only, temp homes; text fields hold "PRIVATE".
func cursorChecks(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokencat-cursor-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let start = ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")!
    func ms(_ seconds: TimeInterval) -> Int64 { Int64(start.addingTimeInterval(seconds).timeIntervalSince1970 * 1_000) }
    func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
    func lines(_ records: [[String: Any]]) -> Data { Data(records.map { json($0) + "\n" }.joined().utf8) }
    func write(_ data: Data, _ url: URL, modified: TimeInterval) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(modified)], ofItemAtPath: url.path)
    }
    func append(_ data: Data, _ url: URL, modified: TimeInterval) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(modified)], ofItemAtPath: url.path)
    }
    /// Writes a database the way Cursor leaves it once it quit: WAL mode, with no `-wal` or `-shm` beside it (Apple's SQLite
    /// keeps an empty WAL after the last connection; Cursor's removes it).
    func database(_ url: URL, wal: Bool = true, _ statements: [(String, [String])]) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        func fill() -> Bool {
            guard sqlite3_open(url.path, &handle) == SQLITE_OK,
                  !wal || sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK else { return false }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (sql, values) in statements {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
                defer { sqlite3_finalize(statement) }
                for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
                guard sqlite3_step(statement) == SQLITE_DONE else { return false }
            }
            return true
        }
        let written = fill()
        sqlite3_close(handle)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        return written
    }
    /// The `projects/<slug>` name Cursor gives a folder: every character but an ASCII letter or digit becomes `-`.
    func slug(_ url: URL) -> String {
        String(String(url.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }).drop { $0 == "-" })
    }
    func user(_ text: String = "<user_query>PRIVATE_PROMPT</user_query>") -> [String: Any] {
        ["role": "user", "message": ["content": [["type": "text", "text": text]]]]
    }
    func assistant(_ tools: [String] = []) -> [String: Any] {
        ["role": "assistant", "message": ["content": [["type": "text", "text": "PRIVATE_REPLY"]]
            + tools.map { ["type": "tool_use", "name": $0, "input": ["command": "PRIVATE_INPUT"]] }]]
    }
    func ended(_ status: String) -> [String: Any] {
        status == "success" ? ["type": "turn_ended", "status": status] : ["type": "turn_ended", "status": status, "error": "PRIVATE_ERROR"]
    }

    check(CursorLog.promptTime("<timestamp>Friday, Jul 17, 2026, 12:26 AM (UTC+9)</timestamp>\n<user_query>x</user_query>")
            == ISO8601DateFormatter().date(from: "2026-07-16T15:26:00Z")
          && CursorLog.promptTime("<timestamp>Monday, Oct 5, 2026, 9:05 PM (UTC-5:30)</timestamp>")
            == ISO8601DateFormatter().date(from: "2026-10-06T02:35:00Z")
          && CursorLog.promptTime("<timestamp>Friday, Jul 17, 2026, 12:26 AM (UTC)</timestamp>")
            == ISO8601DateFormatter().date(from: "2026-07-17T00:26:00Z")
          && CursorLog.promptTime("<user_query><timestamp>Friday, Jul 17, 2026, 12:26 AM (UTC+9)</timestamp></user_query>") == nil
          && CursorLog.promptTime("<timestamp>yesterday (UTC+9)</timestamp>") == nil,
          "Cursor: a prompt's <timestamp> tag was misread, or a tag not leading the prompt was read")
    do {
        let home = root.appendingPathComponent("home")
        let projects = home.appendingPathComponent(".cursor/projects")
        // The workspace a slug stands for, beside a decoy that matches only its first word.
        let workspace = root.appendingPathComponent("Work Space/my_app.v2")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Work"), withIntermediateDirectories: true)
        let transcripts = projects.appendingPathComponent(slug(workspace)).appendingPathComponent("agent-transcripts")
        let main = transcripts.appendingPathComponent("cur-main/cur-main.jsonl")
        try write(lines([user("<timestamp>Sunday, Oct 4, 2026, 9:00 PM (UTC+9)</timestamp>\n<user_query>PRIVATE_PROMPT</user_query>"),
                         assistant(["Shell"])]), main, modified: 10)
        let sub = transcripts.appendingPathComponent("cur-main/subagents/cur-sub.jsonl")
        try write(lines([user(), assistant(["Read"])]), sub, modified: 8)
        let failed = transcripts.appendingPathComponent("cur-error.jsonl")
        try write(lines([user(), assistant(["Grep"]), ended("error")]), failed, modified: 5)
        let legacy = transcripts.appendingPathComponent("cur-legacy.txt")
        try write(Data("user:\nPRIVATE_PROMPT\n\nassistant:\nPRIVATE_REPLY\n[Tool call] Read\n  path: PRIVATE_PATH\n".utf8), legacy, modified: 10)
        let ide = projects.appendingPathComponent("Users-nobody-tokencat-fixture/agent-transcripts/cur-ide/cur-ide.jsonl")
        try write(lines([user(), assistant(["Shell"])]), ide, modified: 10)
        let empty = projects.appendingPathComponent("empty-window/agent-transcripts/cur-empty/cur-empty.jsonl")
        try write(lines([user(), assistant(), ended("success")]), empty, modified: 4)
        let gone = projects.appendingPathComponent(slug(root.appendingPathComponent("gone dir"))).appendingPathComponent("agent-transcripts/cur-gone.jsonl")
        try write(lines([user(), assistant(), ended("success")]), gone, modified: 3)
        // Folders Cursor recorded resolve a slug without opening any folder: the CLI's state file and the IDE's workspaces.
        let cliFolder = home.appendingPathComponent("Code/agent app")
        try write(Data(json(["version": 1, "workerIdsByDisplayName": ["~/Code/agent app @ PRIVATE_HOST": "w-1"]]).utf8),
                  home.appendingPathComponent(".cursor/agent-cli-state.json"), modified: 0)
        try write(lines([user(), assistant(), ended("success")]),
                  projects.appendingPathComponent(slug(cliFolder)).appendingPathComponent("agent-transcripts/cur-cli/cur-cli.jsonl"), modified: 2)
        try write(lines([user(), assistant(), ended("success")]),
                  projects.appendingPathComponent("tmp-CursorIDEProject/agent-transcripts/cur-ws/cur-ws.jsonl"), modified: 2)
        // The cursor-agent CLI's chat store names the model of a session the IDE does not know.
        let meta = json(["agentId": "cur-main", "name": "PRIVATE_NAME", "lastUsedModel": "gpt-5.1-codex", "blobEncryptionKey": "PRIVATE_KEY"])
        let hex = Data(meta.utf8).map { String(format: "%02x", $0) }.joined()
        let globalStorage = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
        let state = globalStorage.appendingPathComponent("state.vscdb")
        func header(_ id: String, pending: Bool) -> String {
            json(["composerId": id, "name": "Fix login redirect", "hasBlockingPendingActions": pending, "contextUsagePercent": 25,
                  "workspaceIdentifier": ["id": "w1", "uri": ["fsPath": "/tmp/CursorIDEProject", "scheme": "file"]],
                  "lastUpdatedAt": ms(11), "subtitle": "PRIVATE_SUBTITLE"])
        }
        guard database(home.appendingPathComponent(".cursor/chats/0123abcd/cur-main/store.db"), wal: false, [
            ("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)", []), ("INSERT INTO meta VALUES ('0', ?)", [hex]),
            ("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)", []),
        ]), database(state, [
            ("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", []),
            ("CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", []),
            ("CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, "
                + "isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT)", []),
            ("INSERT INTO composerHeaders (composerId, lastUpdatedAt, isSubagent, value) VALUES ('cur-ide', \(ms(11)), 0, ?)",
             [header("cur-ide", pending: true)]),
            ("INSERT INTO composerHeaders (composerId, lastUpdatedAt, isSubagent, value, subagentTypeName) VALUES ('cur-sub', \(ms(8)), 1, ?, 'explore')",
             [json(["composerId": "cur-sub", "lastUpdatedAt": ms(8)])]),
            ("INSERT INTO composerHeaders (composerId, lastUpdatedAt, isSubagent, value) VALUES ('cur-error', \(ms(5)), 0, ?)",
             [json(["composerId": "cur-error", "workspaceIdentifier": ["uri": ["fsPath": "/tmp/CursorIDEProject"]], "lastUpdatedAt": ms(5)])]),
            ("INSERT INTO cursorDiskKV VALUES ('composerData:cur-ide', ?)",
             [json(["composerId": "cur-ide", "text": "PRIVATE_DRAFT", "modelConfig": ["modelName": "default"], "contextTokensUsed": 50_000,
                    "contextTokenLimit": 200_000, "lastUpdatedAt": ms(11),
                    "fullConversationHeadersOnly": [["bubbleId": "b1", "type": 1], ["bubbleId": "b2", "type": 2]]])]),
            ("INSERT INTO cursorDiskKV VALUES ('bubbleId:cur-ide:b1', ?)",
             [json(["type": 1, "text": "PRIVATE_PROMPT", "modelInfo": ["modelName": "claude-4.5-sonnet"]])]),
            ("INSERT INTO cursorDiskKV VALUES ('bubbleId:cur-ide:b2', ?)", [json(["type": 2, "text": "PRIVATE_REPLY", "modelInfo": ["modelName": "other"]])]),
            ("INSERT INTO cursorDiskKV VALUES ('composerData:cur-error', ?)",
             [json(["composerId": "cur-error", "modelConfig": ["modelName": "gpt-5"], "gitWorktree": ["worktreePath": "/tmp/CursorWorktree"],
                    "lastUpdatedAt": ms(5)])]),
        ]) else { return check(false, "Cursor fixture: databases not written") }
        check(!FileManager.default.fileExists(atPath: state.path + "-wal")
              && OpenCodeDatabase(path: state.path)?.query("SELECT 1 FROM composerHeaders", row: { _ in }) != true,
              "Cursor fixture: the IDE database read without its WAL as a plain read-only connection, so the snapshot path goes untested")

        var now = start.addingTimeInterval(12)
        let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now })
        var rows = tracker.sample()
        func row(_ session: String) -> TokenReading? { rows.first { $0.source == .cursor && $0.sessionID == session } }
        let open = row("cur-main")
        check(open?.activityState == .tool && open?.active == true && open?.toolName == "Shell" && open?.toolCategory == .command
              && open?.currentTurnStartedAt == start && open?.currentTurnOutputTokens == nil && open?.lastActivity == start.addingTimeInterval(10),
              "Cursor: an open turn with a tool use was not a live tool turn dated by its prompt's timestamp tag, or counted output")
        check(open?.project == "my_app.v2" && open?.projectPath == workspace.path && open?.title == nil && open?.model == "gpt-5.1-codex"
              && open?.isSubagent == false,
              "Cursor: the project slug was not matched to its existing folder, or the CLI store's model was missed")
        let child = row("cur-sub")
        check(child?.isSubagent == true && child?.parentSessionID == "cur-main" && child?.agentID == "cur-sub" && child?.agentRole == "explore"
              && child?.activityState == .tool && child?.toolName == "Read" && child?.toolCategory == .file && child?.project == "my_app.v2",
              "Cursor: a subagent transcript was not grouped under its parent with its type, tool and project")
        let error = row("cur-error")
        check(error?.activityState == .interrupted && error?.active == false && error?.toolName == nil
              && error?.project == "CursorWorktree" && error?.projectPath == "/tmp/CursorWorktree" && error?.model == "gpt-5" && error?.title == nil,
              "Cursor: a turn ended with an error was not interrupted, or the composer's worktree did not win over its workspace")
        let ideRow = row("cur-ide")
        check(ideRow?.activityState == .input && ideRow?.active == true && ideRow?.toolName == "Shell" && ideRow?.title == "Fix login redirect"
              && ideRow?.model == "claude-4.5-sonnet" && ideRow?.project == "CursorIDEProject" && ideRow?.projectPath == "/tmp/CursorIDEProject"
              && ideRow?.context?.usedTokens == 50_000 && ideRow?.context?.windowTokens == 200_000
              && ideRow?.context?.recordedAt == start.addingTimeInterval(11) && ideRow?.lastLogAt == start.addingTimeInterval(11),
              "Cursor: the IDE database's title, pending action, workspace, latest request model or context was not read")
        check(row("cur-empty")?.project == "empty-window" && row("cur-empty")?.projectPath == nil && row("cur-empty")?.activityState == .complete
              && row("cur-gone")?.project == "gone-dir" && row("cur-gone")?.projectPath == nil,
              "Cursor: a slug without a folder was not shown as is, or a deleted folder lost its own name")
        check(row("cur-cli")?.project == "agent app" && row("cur-cli")?.projectPath == cliFolder.path
              && row("cur-ws")?.project == "CursorIDEProject" && row("cur-ws")?.projectPath == "/tmp/CursorIDEProject",
              "Cursor: a slug was not matched to a folder the CLI state or an IDE composer recorded")
        check(row("cur-legacy")?.activityState == .tool && row("cur-legacy")?.toolName == "Read",
              "Cursor: a legacy text transcript's open tool call was not shown")

        // The step after the tool, then the end of the turn; the approval is granted in the IDE.
        try append(lines([assistant()]), main, modified: 20)
        try append(Data("[Tool result]\n  PRIVATE_RESULT\nPRIVATE_ANSWER\n".utf8), legacy, modified: 20)
        guard database(state, [("UPDATE composerHeaders SET value = ? WHERE composerId = 'cur-ide'", [header("cur-ide", pending: false)])])
        else { return check(false, "Cursor fixture: the IDE database was not updated") }
        now = start.addingTimeInterval(21)
        rows = tracker.sample()
        check(row("cur-main")?.activityState == .working && row("cur-main")?.toolName == nil && row("cur-main")?.lastActivity == start.addingTimeInterval(20)
              && row("cur-ide")?.activityState == .tool && row("cur-legacy")?.activityState == .complete,
              "Cursor: a later step did not end the tool run, a granted approval stayed input, or legacy answer text did not complete the turn")
        try append(lines([ended("success")]), main, modified: 30)
        now = start.addingTimeInterval(31)
        rows = tracker.sample()
        let done = row("cur-main")
        check(done?.activityState == .complete && done?.active == false && done?.currentTurnStartedAt == nil && done?.lastOutputTokens == nil
              && done?.lastActivity == start.addingTimeInterval(30),
              "Cursor: turn_ended success did not complete the turn at the transcript's write time")
        let encoded = (try? JSONEncoder().encode(rows.filter { $0.source == .cursor })).map { String(decoding: $0, as: UTF8.self) } ?? "PRIVATE"
        check(rows.filter { $0.source == .cursor }.count == 9 && !encoded.contains("PRIVATE"),
              "Cursor: a transcript was not listed, or prompt, reply, tool input or store text leaked into a reading")
        check(tracker.isLog(main.path) && tracker.isLog(sub.path) && tracker.isLog(failed.path) && tracker.isLog(legacy.path)
              && !tracker.isLog(transcripts.appendingPathComponent("cur-main/notes.jsonl").path)
              && !tracker.isLog(transcripts.appendingPathComponent("cur-main/subagents/notes.txt").path)
              && !tracker.isLog(projects.appendingPathComponent("empty-window/terminals/1.txt").path),
              "Cursor: a changed path was matched to the wrong file of a project folder")

        // Older IDE builds keep the headers as one JSON value in ItemTable.
        let oldHome = root.appendingPathComponent("old-home")
        try write(lines([user(), assistant(), ended("success")]),
                  oldHome.appendingPathComponent(".cursor/projects/Users-nobody-old/agent-transcripts/cur-old/cur-old.jsonl"), modified: 5)
        guard database(oldHome.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"), [
            ("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", []),
            ("INSERT INTO ItemTable VALUES ('composer.composerHeaders', ?)", [json(["allComposers": [
                ["composerId": "cur-old", "name": "Old fixture title", "lastUpdatedAt": ms(5),
                 "workspaceIdentifier": ["uri": ["fsPath": "/tmp/CursorOldProject"]]]]])]),
        ]) else { return check(false, "Cursor fixture: the legacy IDE database was not written") }
        let old = TokenTracker(homeDirectory: oldHome, environment: [:], now: { now }).sample().first { $0.sessionID == "cur-old" }
        check(old?.title == "Old fixture title" && old?.project == "CursorOldProject" && old?.activityState == .complete,
              "Cursor: composer headers kept in ItemTable (older builds) were not read")
    } catch {
        check(false, "Cursor fixtures could not be written: \(error)")
    }
}
