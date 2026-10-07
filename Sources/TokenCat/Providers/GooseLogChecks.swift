import Foundation
import SQLite3

/// Goose fixture database (synthetic metadata; every text field is a "PRIVATE" marker): turn state, tool, approval wait,
/// ledger output, model, project, subagent, title rules, measured speed and an incremental update. The tables are Goose's
/// own `create_schema` DDL (crates/goose/src/session/session_manager.rs, schema version 16). Run from `runTrackerChecks`.
func gooseLogChecks(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokencat-goose-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = ISO8601DateFormatter().date(from: "2026-10-04T06:00:00Z")!
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    func seconds(_ offset: TimeInterval) -> Int64 { Int64(now.addingTimeInterval(offset).timeIntervalSince1970) }
    /// SQLite's `datetime('now')` text, as Goose writes `updated_at` and `timestamp`.
    func stamp(_ offset: TimeInterval) -> String { formatter.string(from: now.addingTimeInterval(offset)) }
    func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
    func text() -> [String: Any] { ["type": "text", "text": "PRIVATE_REPLY"] }
    func request(_ id: String, _ name: String) -> [String: Any] {
        ["type": "toolRequest", "id": id, "toolCall": ["status": "success", "value": ["name": name, "arguments": ["command": "PRIVATE_CMD"]]]]
    }
    func response(_ id: String) -> [String: Any] {
        ["type": "toolResponse", "id": id,
         "toolResult": ["status": "success", "value": ["content": [["type": "text", "text": "PRIVATE_OUT"]], "isError": false]]]
    }
    func metadata(visible: Bool = true, output: Int? = nil, elapsed: Int? = nil, ttft: Int? = nil) -> String {
        var value: [String: Any] = ["userVisible": visible, "agentVisible": true]
        if let output {
            var usage: [String: Any] = ["outputTokens": output, "inputTokens": 9_000]
            if let elapsed { usage["elapsedMs"] = elapsed }
            if let ttft { usage["timeToFirstTokenMs"] = ttft }
            value["usage"] = usage
            value["inference"] = ["provider": "anthropic", "requestedModel": "claude-fixture", "resolvedModel": "claude-fixture-4"]
        }
        return json(value)
    }

    let home = root.appendingPathComponent("goose-home")
    let folder = home.appendingPathComponent(".local/share/goose/sessions")
    let path = folder.appendingPathComponent("sessions.db").path
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    do { try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true) } catch {
        return check(false, "Goose fixture error: \(error.localizedDescription)")
    }
    guard sqlite3_open(path, &database) == SQLITE_OK else { return check(false, "Goose fixture: database not created") }
    var failed = false
    func run(_ sql: String, _ values: [Any?] = []) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { failed = true; return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            switch value {
            case let text as String: sqlite3_bind_text(statement, Int32(index + 1), text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let number as Int64: sqlite3_bind_int64(statement, Int32(index + 1), number)
            case let number as Int: sqlite3_bind_int64(statement, Int32(index + 1), Int64(number))
            default: sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        if sqlite3_step(statement) != SQLITE_DONE { failed = true }
    }
    run("""
        CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
            user_set_name BOOLEAN DEFAULT FALSE, session_type TEXT NOT NULL DEFAULT 'user', working_dir TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, extension_data TEXT DEFAULT '{}',
            total_tokens INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
            accumulated_total_tokens INTEGER, accumulated_input_tokens INTEGER, accumulated_output_tokens INTEGER,
            accumulated_cache_read_tokens INTEGER, accumulated_cache_write_tokens INTEGER, accumulated_cost REAL, schedule_id TEXT,
            recipe_json TEXT, user_recipe_values_json TEXT, provider_name TEXT, model_config_json TEXT,
            goose_mode TEXT NOT NULL DEFAULT 'auto', archived_at TIMESTAMP, project_id TEXT, parent_session_id TEXT)
        """)
    run("""
        CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT, session_id TEXT NOT NULL REFERENCES sessions(id),
            role TEXT NOT NULL, content_json TEXT NOT NULL, created_timestamp INTEGER NOT NULL, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            tokens INTEGER, metadata_json TEXT)
        """)
    run("""
        CREATE TABLE usage_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            created_timestamp INTEGER NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER,
            cache_read_tokens INTEGER, cache_write_tokens INTEGER, cost REAL, cost_source TEXT, is_compaction INTEGER DEFAULT 0)
        """)
    func session(_ id: String, name: String, userSet: Bool = false, type: String = "user", directory: String, updated: TimeInterval,
                 provider: String = "anthropic", parent: String? = nil, archived: Bool = false) {
        run("""
            INSERT INTO sessions (id, name, user_set_name, session_type, working_dir, created_at, updated_at, provider_name,
                model_config_json, archived_at, parent_session_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [id, name, userSet ? 1 : 0, type, directory, stamp(-3_000), stamp(updated), provider,
                  json(["model_name": "fixture-session-model", "temperature": NSNull(), "max_tokens": NSNull(), "toolshim": false,
                        "toolshim_model": NSNull()]), archived ? stamp(updated) : nil, parent])
    }
    func message(_ session: String, _ role: String, _ at: TimeInterval, _ content: [[String: Any]], _ meta: String? = nil) {
        run("INSERT INTO messages (message_id, session_id, role, content_json, created_timestamp, timestamp, metadata_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ["msg_\(session)_\(UUID().uuidString)", session, role, json(content), seconds(at), stamp(at), meta ?? metadata()])
    }
    func ledger(_ session: String, _ at: TimeInterval, output: Int, input: Int = 9_000, source: String? = nil) {
        run("INSERT INTO usage_ledger (session_id, created_timestamp, model, input_tokens, output_tokens, total_tokens, cost_source) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [session, seconds(at), source == nil ? "claude-fixture-4" : nil, input, output, input + output, source])
    }

    // A working turn: an agent-only turn-context message does not reopen it, one shell call returned, the next runs.
    session("ses_work", name: "Fix flaky\nlogin test", directory: "/tmp/GooseWork", updated: -10)
    message("ses_work", "user", -40, [["type": "text", "text": "PRIVATE_PROMPT"]])
    message("ses_work", "user", -39, [["type": "text", "text": "PRIVATE_CONTEXT"]], metadata(visible: false))
    message("ses_work", "assistant", -30, [text(), request("t1", "shell")], metadata(output: 120, elapsed: 3_000, ttft: 400))
    ledger("ses_work", -30, output: 120)
    message("ses_work", "user", -20, [response("t1")])
    message("ses_work", "assistant", -10, [request("t2", "shell")], metadata(output: 30, elapsed: 1_500, ttft: 200))
    ledger("ses_work", -10, output: 30, input: 9_500)
    // A finished turn; the ACP placeholder name is no title, and the backfilled carried_forward row is no model call.
    session("ses_done", name: "New Chat", directory: "/tmp/GooseDone", updated: -100, provider: "openai")
    message("ses_done", "user", -200, [["type": "text", "text": "PRIVATE_PROMPT"]])
    message("ses_done", "assistant", -150, [["type": "thinking", "thinking": "PRIVATE", "signature": "PRIVATE"], text()],
            metadata(output: 400, elapsed: 8_000))
    ledger("ses_done", -150, output: 400)
    ledger("ses_done", -100, output: 999, source: "carried_forward")
    // A subagent whose shell call waits for the person's approval.
    session("ses_ask", name: "Delegated task", type: "sub_agent", directory: "/tmp/GooseWork", updated: -25, parent: "ses_work")
    message("ses_ask", "user", -28, [["type": "text", "text": "PRIVATE_TASK"]])
    message("ses_ask", "assistant", -26, [request("t9", "developer__shell")])
    message("ses_ask", "assistant", -25, [["type": "actionRequired", "data": ["actionType": "toolConfirmation", "id": "t9",
                                                                             "toolName": "developer__shell", "arguments": ["command": "PRIVATE"],
                                                                             "prompt": "PRIVATE"]]])
    // claude-code names a session from the first prompt's first words (no title until the person renames it) and logs its
    // own tokens, which the Claude Code reader counts: its finished turn and new prompt report no output or speed here.
    session("ses_cli", name: "PRIVATE fix the bug", directory: "/tmp/GooseCli", updated: -3, provider: "claude-code")
    message("ses_cli", "user", -50, [["type": "text", "text": "PRIVATE_PROMPT"]])
    message("ses_cli", "assistant", -45, [text()], metadata(output: 70, elapsed: 700))
    ledger("ses_cli", -45, output: 70, input: 7_000)
    message("ses_cli", "user", -3, [["type": "text", "text": "PRIVATE_PROMPT"]])
    // A fresh prompt on a model provider opens a turn at zero output.
    session("ses_new", name: "New Chat", directory: "/tmp/GooseNew", updated: -4)
    message("ses_new", "user", -4, [["type": "text", "text": "PRIVATE_PROMPT"]])
    // A provider error ends the turn.
    session("ses_err", name: "Broken request", directory: "/tmp/GooseErr", updated: -60)
    message("ses_err", "user", -70, [["type": "text", "text": "PRIVATE_PROMPT"]])
    message("ses_err", "assistant", -60, [["type": "error", "kind": "authentication", "message": "PRIVATE_ERR"]])
    // Archived sessions are not listed.
    session("ses_old", name: "Old work", directory: "/tmp/GooseOld", updated: -1, archived: true)
    message("ses_old", "user", -1, [["type": "text", "text": "PRIVATE_PROMPT"]])
    guard !failed else { return check(false, "Goose fixture: SQL failed") }

    let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
    let rows = tracker.sample().filter { $0.source == .goose }
    func row(_ id: String) -> TokenReading? { rows.first { $0.sessionID == id } }
    let work = row("ses_work")
    check(work?.active == true && work?.activityState == .tool && work?.toolName == "shell" && work?.toolCategory == .command
          && work?.currentTurnStartedAt == now.addingTimeInterval(-40) && work?.currentTurnOutputTokens == 150
          && work?.model == "claude-fixture-4" && work?.project == "GooseWork" && work?.projectPath == "/tmp/GooseWork"
          && work?.context?.usedTokens == 9_500 && work?.isSubagent == false && work?.id.hasSuffix("sessions.db#ses_work") == true
          && work?.title == "Fix flaky login test",
          "Goose: a working turn running shell lost its state, turn start, ledger output, model, project, context or generated title")
    let speed = work?.speedMeasurement
    check(speed?.kind == .requestProcessing && speed?.outputTokens == 30 && speed?.requestDurationMs == 1_500 && speed?.ttftMs == 200
          && speed?.tokensPerSecond == 20 && speed?.model == "claude-fixture-4" && speed?.at == now.addingTimeInterval(-10),
          "Goose: measured speed is not the newest reply's output tokens over its recorded elapsedMs")
    let done = row("ses_done")
    check(done?.active == false && done?.activityState == .complete && done?.lastOutputTokens == 400
          && done?.currentTurnStartedAt == nil && done?.currentTurnOutputTokens == nil && done?.measurementAt == now.addingTimeInterval(-150)
          && done?.speedMeasurement?.tokensPerSecond == 50 && done?.title == nil && done?.recentOutputs.map(\.tokens) == [400],
          "Goose: a finished turn is not complete with its output and speed, the carried_forward row counted, or the placeholder title showed")
    let ask = row("ses_ask")
    check(ask?.activityState == .input && ask?.active == true && ask?.toolName == "developer__shell" && ask?.toolCategory == .command
          && ask?.isSubagent == true && ask?.parentSessionID == "ses_work" && ask?.agentID == "ses_ask" && ask?.title == nil
          && ask?.model == "fixture-session-model",
          "Goose: a subagent waiting for tool approval is not input under its parent, or showed its placeholder title")
    let fresh = row("ses_new")
    check(fresh?.activityState == .working && fresh?.active == true && fresh?.currentTurnStartedAt == now.addingTimeInterval(-4)
          && fresh?.currentTurnOutputTokens == 0 && row("ses_cli")?.title == nil,
          "Goose: a fresh prompt did not open a turn at zero output, or a name cut from the prompt showed as title")
    let cli = row("ses_cli")
    check(cli?.activityState == .working && cli?.active == true && cli?.currentTurnStartedAt == now.addingTimeInterval(-3)
          && cli?.currentTurnOutputTokens == nil && cli?.lastOutputTokens == nil && cli?.lastOutputAt == nil
          && cli?.recentOutputs.isEmpty == true && cli?.speedMeasurement == nil && cli?.context?.usedTokens == 7_000
          && done?.lastOutputTokens == 400 && done?.speedMeasurement != nil,
          "Goose: a CLI or ACP agent provider's session reported output or speed its own log already counts, or a model provider's did not")
    check(row("ses_err")?.activityState == .interrupted && row("ses_err")?.active == false && row("ses_err")?.title == "Broken request"
          && rows.count == 6 && row("ses_old") == nil,
          "Goose: an error reply did not end the turn as interrupted, or archived sessions were listed")
    let encoded = String(decoding: (try? JSONEncoder().encode(rows)) ?? Data(), as: UTF8.self)
    check(!encoded.contains("PRIVATE"), "Goose: message text, tool arguments or a prompt-cut name leaked into a reading")
    check(tracker.isLog(path) && !tracker.isLog(folder.appendingPathComponent("other.db").path) && !tracker.isLog(path + "-wal")
          && tracker.wakesSampling(path + "-wal"),
          "Goose: database file matching is wrong")
    let goose = TokenProvider.all.first { $0.source == .goose }
    check(goose?.roots(home, ["GOOSE_PATH_ROOT": "/tmp/goose-root", "XDG_DATA_HOME": "/tmp/xdg"]).map(\.path)
          == ["/tmp/goose-root/data/sessions", "/tmp/xdg/goose/sessions"]
          && goose?.roots(home, [:]).map(\.path) == [folder.path],
          "Goose: roots are not $GOOSE_PATH_ROOT/data/sessions and the default data folder's sessions")
    check(GooseLog.title("Fix it", userSet: false, provider: "codex-acp", recipe: false) == nil
          && GooseLog.title("Fix it", userSet: true, provider: "codex-acp", recipe: false) == "Fix it"
          && GooseLog.title("Release notes", userSet: false, provider: "cursor-agent", recipe: true) == "Release notes"
          && GooseLog.title("CLI Session", userSet: false, provider: nil, recipe: false) == nil
          && GooseLog.category("github__create_issue") == .mcp && GooseLog.category("delegate") == .agent
          && GooseLog.category("developer__text_editor") == .file,
          "Goose: title or tool category rules are wrong")

    // The shell step returns and a reply ends the turn; the person renames the claude-code session.
    message("ses_work", "user", -6, [response("t2")])
    message("ses_work", "assistant", -2, [text()], metadata(output: 50, elapsed: 1_000))
    ledger("ses_work", -2, output: 50)
    run("UPDATE sessions SET updated_at = ? WHERE id = 'ses_work'", [stamp(-2)])
    run("UPDATE sessions SET name = 'Renamed by me', user_set_name = TRUE, updated_at = ? WHERE id = 'ses_cli'", [stamp(-1)])
    let updated = tracker.sample().filter { $0.source == .goose }
    let finished = updated.first { $0.sessionID == "ses_work" }
    check(!failed && finished?.activityState == .complete && finished?.active == false && finished?.lastOutputTokens == 200
          && finished?.toolName == nil && finished?.speedMeasurement?.tokensPerSecond == 50
          && finished?.recentOutputs.map(\.tokens) == [120, 30, 50]
          && updated.first { $0.sessionID == "ses_cli" }?.title == "Renamed by me",
          "Goose: a finished step or a rename was not picked up incrementally, or the turn total and speed are wrong")
}
