import Foundation
import SQLite3

/// Hermes Agent fixture stores (synthetic metadata; every text column holds a PRIVATE marker): an open tool turn, a
/// question waiting in a subagent, a compression chain as one row, a turn only agent.log ended, a profile database whose
/// writer closed (no `-wal`), token growth into a whole turn, and no text in any reading. Run from `runTrackerChecks`.
func runHermesLogChecks(root: URL, check: (Bool, String) -> Void) {
    let now = ISO8601DateFormatter().date(from: "2026-10-04T06:00:00Z")!
    func at(_ seconds: TimeInterval) -> Double { now.addingTimeInterval(seconds).timeIntervalSince1970 }
    let logFormatter = DateFormatter()
    logFormatter.calendar = Calendar(identifier: .gregorian)
    logFormatter.locale = Locale(identifier: "en_US_POSIX")
    logFormatter.timeZone = .autoupdatingCurrent
    logFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
    func logLine(_ seconds: TimeInterval, _ level: String, _ session: String, _ text: String) -> String {
        "\(logFormatter.string(from: now.addingTimeInterval(seconds))) \(level) [\(session)] \(text)\n"
    }

    let home = root.appendingPathComponent("hermes-home")
    let hermes = home.appendingPathComponent(".hermes")
    let profile = hermes.appendingPathComponent("profiles/work")
    let logs = hermes.appendingPathComponent("logs")
    do {
        for folder in [logs, profile] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    } catch {
        return check(false, "Hermes fixture error: \(error.localizedDescription)")
    }
    let path = hermes.appendingPathComponent("state.db").path
    let profilePath = profile.appendingPathComponent("state.db").path
    var failed = false
    func open(_ path: String) -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { failed = true; return nil }
        return database
    }
    func run(_ database: OpaquePointer?, _ sql: String, _ values: [Any?] = []) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { failed = true; return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            switch value {
            case let text as String: sqlite3_bind_text(statement, Int32(index + 1), text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let number as Double: sqlite3_bind_double(statement, Int32(index + 1), number)
            case let number as Int: sqlite3_bind_int64(statement, Int32(index + 1), Int64(number))
            default: sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        if sqlite3_step(statement) != SQLITE_DONE { failed = true }
    }
    // The subset of Hermes's schema (v26) the reader touches, with its text columns.
    func schema(_ database: OpaquePointer?) {
        run(database, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, model_config TEXT, system_prompt TEXT,
            parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL, end_reason TEXT, message_count INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0, cwd TEXT, title TEXT, title_source TEXT, last_activity_at REAL,
            last_activity_description TEXT, archived INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0)
            """)
        run(database, """
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT,
            tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL NOT NULL, finish_reason TEXT, reasoning TEXT,
            observed INTEGER DEFAULT 0, active INTEGER NOT NULL DEFAULT 1, display_kind TEXT)
            """)
        run(database, "CREATE INDEX idx_messages_session_id ON messages(session_id, id)")
        run(database, "CREATE TABLE session_model_usage (session_id TEXT, model TEXT, task TEXT, output_tokens INTEGER, last_seen REAL)")
        run(database, "CREATE TABLE session_turn_leases (conversation_id TEXT PRIMARY KEY, holder TEXT NOT NULL, acquired_at REAL NOT NULL, expires_at REAL NOT NULL)")
    }
    func session(_ database: OpaquePointer?, _ id: String, source: String = "cli", parent: String? = nil, config: String? = nil,
                 started: TimeInterval, ended: TimeInterval? = nil, reason: String? = nil, output: Int = 0, cwd: String?,
                 title: String? = nil, titleSource: String? = "llm", activity: TimeInterval, archived: Bool = false) {
        run(database, "INSERT INTO sessions VALUES (?, ?, 'session-model', ?, 'PRIVATE system prompt', ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, 'PRIVATE activity', ?, 0)",
            [id, source, config, parent, at(started), ended.map(at), reason, output, cwd, title, title == nil ? nil : titleSource,
             at(activity), archived ? 1 : 0])
    }
    func message(_ database: OpaquePointer?, _ session: String, _ role: String, _ seconds: TimeInterval, finish: String? = nil,
                 calls: [(String, String)] = [], result: String? = nil, kind: String? = nil) {
        let toolCalls = calls.isEmpty ? nil : String(decoding: try! JSONSerialization.data(withJSONObject: calls.map { id, name in
            ["id": id, "call_id": id, "type": "function", "function": ["name": name, "arguments": "{\"command\":\"PRIVATE argument\"}"]]
        }), as: UTF8.self)
        run(database, "INSERT INTO messages (session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, finish_reason, reasoning, display_kind) VALUES (?, ?, 'PRIVATE content', ?, ?, ?, ?, ?, 'PRIVATE reasoning', ?)",
            [session, role, result, toolCalls, result == nil ? nil : "terminal", at(seconds), finish, kind])
    }

    let database = open(path)
    defer { sqlite3_close(database) }
    schema(database)
    // An open turn: the first of two tool calls returned, read_file still runs.
    session(database, "ses_tool", started: -60, output: 1_000, cwd: "/tmp/HermesWork", title: "Fix login\nflow", activity: -10)
    message(database, "ses_tool", "user", -30)
    message(database, "ses_tool", "assistant", -10, finish: "tool_calls", calls: [("c1", "terminal"), ("c2", "read_file")])
    message(database, "ses_tool", "tool", -10, result: "c1")
    run(database, "INSERT INTO session_model_usage VALUES ('ses_tool', 'title-model', 'title_generation', 9, ?)", [at(-5)])
    run(database, "INSERT INTO session_model_usage VALUES ('ses_tool', 'fixture-model', '', 900, ?)", [at(-10)])
    // A finished turn whose title Hermes derived from the prompt (no title).
    session(database, "ses_done", started: -200, output: 500, cwd: "/tmp/HermesDone", title: "PRIVATE derived title", titleSource: "derived", activity: -50)
    message(database, "ses_done", "user", -100)
    message(database, "ses_done", "assistant", -50, finish: "stop")
    // A delegated subagent whose second call asks the person.
    session(database, "ses_child", source: "subagent", parent: "ses_tool", config: "{\"_delegate_from\":\"ses_tool\"}", started: -25,
            cwd: nil, activity: -20)
    message(database, "ses_child", "user", -24)
    message(database, "ses_child", "assistant", -20, finish: "tool_calls", calls: [("c3", "terminal"), ("c4", "clarify")])
    message(database, "ses_child", "tool", -20, result: "c3")
    // A compression chain: the prompt sits in the ended first segment, the turn continues in the second.
    session(database, "ses_long", started: -400, ended: -60, reason: "compression", output: 4_000, cwd: "/tmp/HermesLong",
            title: "Long refactor", activity: -60)
    message(database, "ses_long", "user", -200)
    message(database, "ses_long", "assistant", -150, finish: "tool_calls", calls: [("c5", "terminal")])
    message(database, "ses_long", "tool", -150, result: "c5")
    session(database, "ses_long_2", parent: "ses_long", started: -60, output: 300, cwd: "/tmp/HermesLong", title: "Long refactor", activity: -40)
    message(database, "ses_long_2", "user", -60, kind: "hidden")
    message(database, "ses_long_2", "assistant", -40, finish: "tool_calls", calls: [("c6", "patch")])
    message(database, "ses_long_2", "tool", -40, result: "c6")
    // A request that failed after its retries: no assistant message, only agent.log ends the turn.
    session(database, "ses_fail", source: "desktop", started: -90, cwd: nil, activity: -40)
    message(database, "ses_fail", "user", -40)
    // Archived sessions are not listed.
    session(database, "ses_arch", started: -5, cwd: "/tmp/HermesArch", activity: -5, archived: true)
    message(database, "ses_arch", "user", -5)

    // A profile store in WAL mode whose writer closed: SQLite removes its -wal and -shm.
    let profileDatabase = open(profilePath)
    if sqlite3_exec(profileDatabase, "PRAGMA journal_mode=WAL", nil, nil, nil) != SQLITE_OK { failed = true }
    schema(profileDatabase)
    session(profileDatabase, "ses_profile", started: -10, cwd: "/tmp/ProfileProject", activity: -5)
    message(profileDatabase, "ses_profile", "user", -5)
    // Apple's SQLite keeps the WAL after the last close; Hermes's Python build does not.
    var persist: Int32 = 0
    sqlite3_file_control(profileDatabase, "main", SQLITE_FCNTL_PERSIST_WAL, &persist)
    sqlite3_close(profileDatabase)

    var log = logLine(-31, "INFO", "ses_tool", "agent.turn_context: conversation turn: session=ses_tool model=fixture-model msg='PRIVATE prompt'")
    log += logLine(-12, "WARNING", "ses_tool", "agent.conversation_loop: Retrying API call in 2.0s (attempt 1/3) PRIVATE error")
    log += logLine(-11, "INFO", "ses_tool", "agent.conversation_loop: API call #3: model=fixture-model provider=fixture in=42000 out=300 total=42300 latency=6.0s cache=40000/42000 (95%)")
    log += logLine(-41, "INFO", "ses_fail", "agent.turn_context: conversation turn: session=ses_fail model=fixture-model msg='PRIVATE prompt'")
    log += logLine(-30, "ERROR", "ses_fail", "agent.conversation_loop: API call failed after 3 retries. HTTP 429 PRIVATE")
    log += "PRIVATE continuation line of a multi-line record\n"
    let logURL = logs.appendingPathComponent("agent.log")
    guard !failed, (try? log.write(to: logURL, atomically: true, encoding: .utf8)) != nil else {
        return check(false, "Hermes fixture: SQL or log write failed")
    }
    let walGone = !FileManager.default.fileExists(atPath: profilePath + "-wal")

    let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
    var rows = tracker.sample().filter { $0.source == .hermes }
    func row(_ id: String) -> TokenReading? { rows.first { $0.sessionID == id } }
    let work = row("ses_tool")
    check(work?.active == true && work?.activityState == .tool && work?.toolName == "read_file" && work?.toolCategory == .file
          && work?.currentTurnStartedAt == now.addingTimeInterval(-30) && work?.currentTurnOutputTokens == nil
          && work?.model == "fixture-model" && work?.project == "HermesWork" && work?.projectPath == "/tmp/HermesWork"
          && work?.title == "Fix login flow" && work?.isSubagent == false && work?.id.hasSuffix(".hermes/state.db#ses_tool") == true
          && work?.context?.usedTokens == 42_000 && work?.recentOutputs.isEmpty == true,
          "Hermes: an open turn running its second tool lost its state, tool, start, model, project, title or context, or counted the baseline")
    let speed = work?.speedMeasurement
    check(speed?.kind == .requestProcessing && speed?.outputTokens == 300 && speed?.requestDurationMs == 6_000
          && speed?.requestDurationIncludesRetries == true && speed?.model == "fixture-model" && speed?.at == now.addingTimeInterval(-11),
          "Hermes: the agent.log API call line did not give out over latency, flagged with its retry")
    let done = row("ses_done")
    check(done?.active == false && done?.activityState == .complete && done?.title == nil && done?.project == "HermesDone"
          && done?.lastOutputTokens == nil && done?.model == "session-model",
          "Hermes: a finished turn is not complete, counted its baseline, or showed a title derived from the prompt")
    let child = row("ses_child")
    check(child?.activityState == .input && child?.active == true && child?.toolName == "clarify" && child?.toolCategory == .question
          && child?.isSubagent == true && child?.parentSessionID == "ses_tool" && child?.agentID == "ses_child"
          && child?.project == "HermesWork",
          "Hermes: a delegated subagent asking the person is not waiting for input under its parent with the parent's project")
    let chain = row("ses_long")
    check(chain?.activityState == .working && chain?.active == true && chain?.currentTurnStartedAt == now.addingTimeInterval(-200)
          && chain?.title == "Long refactor" && chain?.project == "HermesLong" && chain?.isSubagent == false
          && row("ses_long_2") == nil && chain?.id.hasSuffix("#ses_long") == true,
          "Hermes: a compression chain is not one row named after its first session, with the prompt from the ended segment")
    check(row("ses_fail")?.activityState == .interrupted && row("ses_fail")?.active == false && row("ses_arch") == nil,
          "Hermes: a turn agent.log ended after failed retries stayed open, or an archived session was listed")
    let profileRow = row("ses_profile")
    check(walGone && profileRow?.activityState == .working && profileRow?.project == "ProfileProject"
          && profileRow?.id.hasSuffix("profiles/work/state.db#ses_profile") == true,
          "Hermes: a profile's state.db without its -wal (writer closed) was not discovered or read")
    check(tracker.isLog(path) && tracker.isLog(profilePath) && !tracker.isLog(hermes.appendingPathComponent("hermes-agent/state.db").path)
          && !tracker.isLog(path + "-wal") && !tracker.isLog(logURL.path)
          && HermesLog.root(URL(fileURLWithPath: "/srv/hermes/profiles/coder")).path == "/srv/hermes"
          && HermesLog.root(URL(fileURLWithPath: "/srv/hermes")).path == "/srv/hermes",
          "Hermes: state.db matching or the HERMES_HOME profile root is wrong")

    // The second tool returns and the turn completes; its 500 tokens are logged, but the turn began before the baseline.
    message(database, "ses_tool", "tool", -4, result: "c2")
    message(database, "ses_tool", "assistant", -2, finish: "stop")
    run(database, "UPDATE sessions SET output_tokens = 1500, message_count = 5 WHERE id = 'ses_tool'")
    rows = tracker.sample().filter { $0.source == .hermes }
    let completed = row("ses_tool")
    check(!failed && completed?.activityState == .complete && completed?.active == false && completed?.toolName == nil
          && completed?.lastOutputTokens == nil && completed?.recentOutputs.map(\.tokens) == [500]
          && completed?.recentOutputs.first?.at == now.addingTimeInterval(-2),
          "Hermes: a completed turn did not log its growth at the last message, or counted a turn seen only in part")
    // A new prompt starts a whole turn at zero.
    message(database, "ses_tool", "user", -1.5)
    run(database, "UPDATE sessions SET message_count = 6 WHERE id = 'ses_tool'")
    rows = tracker.sample().filter { $0.source == .hermes }
    check(!failed && row("ses_tool")?.activityState == .working && row("ses_tool")?.currentTurnOutputTokens == 0
          && row("ses_tool")?.currentTurnStartedAt == now.addingTimeInterval(-1.5),
          "Hermes: a new prompt did not open a turn at zero output")
    // Its answer: 120 tokens, its API call and Turn ended lines.
    message(database, "ses_tool", "assistant", -0.5, finish: "stop")
    run(database, "UPDATE sessions SET output_tokens = 1620, message_count = 7 WHERE id = 'ses_tool'")
    let more = logLine(-0.6, "INFO", "ses_tool", "agent.conversation_loop: API call #4: model=fixture-model provider=fixture in=43000 out=120 total=43120 latency=2.0s")
        + logLine(-0.4, "INFO", "ses_tool", "agent.conversation_loop: Turn ended: reason=text_response(finish_reason=stop) model=fixture-model api_calls=1/90 session=ses_tool")
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(more.utf8))
        try? handle.close()
    }
    rows = tracker.sample().filter { $0.source == .hermes }
    let whole = row("ses_tool")
    check(!failed && whole?.activityState == .complete && whole?.lastOutputTokens == 120 && whole?.recentOutputs.map(\.tokens) == [500, 120]
          && whole?.context?.usedTokens == 43_000 && whole?.speedMeasurement?.tokensPerSecond == 60
          && whole?.speedMeasurement?.requestDurationIncludesRetries == false,
          "Hermes: a whole turn's output, context or measured speed is wrong")
    let encoder = JSONEncoder()
    let encoded = rows.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined()
    check(rows.count == 6 && !encoded.isEmpty && !encoded.contains("PRIVATE"),
          "Hermes: a reading carried message, reasoning, argument, prompt or log text")
}
