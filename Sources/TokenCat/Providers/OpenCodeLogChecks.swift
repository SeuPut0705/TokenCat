import Foundation
import SQLite3

/// OpenCode fixture database (synthetic metadata, no transcript text): turn state, tool, input wait, token totals, model,
/// project, subagent, session title, measured speed and an incremental update. Run from `runTrackerChecks`.
func runOpenCodeLogChecks(root: URL, check: (Bool, String) -> Void) {
    let now = ISO8601DateFormatter().date(from: "2026-10-04T06:00:00Z")!
    func ms(_ seconds: TimeInterval) -> Int64 { Int64((now.addingTimeInterval(seconds).timeIntervalSince1970 * 1_000).rounded()) }
    func json(_ value: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
    func assistant(parent: String, created: TimeInterval, completed: TimeInterval? = nil, finish: String? = nil,
                   output: Int = 0, reasoning: Int = 0, cwd: String, agent: String = "build") -> String {
        var time: [String: Any] = ["created": ms(created)]
        if let completed { time["completed"] = ms(completed) }
        var value: [String: Any] = ["role": "assistant", "parentID": parent, "modelID": "fixture-model", "providerID": "fixture",
                                    "agent": agent, "path": ["cwd": cwd, "root": cwd], "time": time,
                                    "tokens": ["input": 1_000, "output": output, "reasoning": reasoning, "cache": ["read": 5_000, "write": 0]]]
        if let finish { value["finish"] = finish }
        return json(value)
    }
    func user(_ created: TimeInterval, padding: Int = 0) -> String {
        json(["role": "user", "time": ["created": ms(created)], "agent": "build", "model": ["providerID": "fixture", "modelID": "fixture-model"],
              "summary": ["diffs": [String(repeating: "x", count: padding)]]])
    }

    let home = root.appendingPathComponent("opencode-home")
    let folder = home.appendingPathComponent(".local/share/opencode")
    let path = folder.appendingPathComponent("opencode.db").path
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    do { try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true) } catch {
        check(false, "OpenCode fixture error: \(error.localizedDescription)")
        return
    }
    guard sqlite3_open(path, &database) == SQLITE_OK else { return check(false, "OpenCode fixture: database not created") }
    var failed = false
    func run(_ sql: String, _ values: [Any?] = []) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { failed = true; return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            switch value {
            case let text as String: sqlite3_bind_text(statement, Int32(index + 1), text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let number as Int64: sqlite3_bind_int64(statement, Int32(index + 1), number)
            default: sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        if sqlite3_step(statement) != SQLITE_DONE { failed = true }
    }
    run("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT NOT NULL, agent TEXT, model TEXT, time_updated INTEGER NOT NULL, time_archived INTEGER)")
    run("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)")
    run("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)")
    /// The title defaults to OpenCode's placeholder, which is no title.
    func session(_ id: String, parent: String? = nil, directory: String, title: String? = nil, agent: String = "build",
                 updated: TimeInterval, archived: Bool = false) {
        run("INSERT INTO session VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [id, parent, directory, title ?? "\(parent == nil ? "New" : "Child") session - 2026-10-04T05:00:00.000Z", agent,
             json(["id": "session-model", "providerID": "fixture"]), ms(updated), archived ? ms(updated) : nil])
    }
    func message(_ id: String, _ session: String, created: TimeInterval, updated: TimeInterval, _ data: String) {
        run("INSERT OR REPLACE INTO message VALUES (?, ?, ?, ?, ?)", [id, session, ms(created), ms(updated), data])
    }
    func part(_ id: String, _ message: String, _ session: String, updated: TimeInterval, _ data: [String: Any]) {
        run("INSERT OR REPLACE INTO part VALUES (?, ?, ?, ?, ?, ?)", [id, message, session, ms(updated), ms(updated), json(data)])
    }
    // A working turn: one step ended in tool calls, the next runs bash. Its 320 tokens over created → last generated part
    // (the write tool's execution start, -12 s, after reasoning and text) are 6 s: 53.3 tok/s.
    session("ses_work", directory: "/tmp/WorkProject", title: "Fix flaky\nlogin test", updated: -2)
    message("u1", "ses_work", created: -20, updated: -20, user(-20))
    message("a1", "ses_work", created: -18, updated: -10,
            assistant(parent: "u1", created: -18, completed: -10, finish: "tool-calls", output: 300, reasoning: 20, cwd: "/tmp/WorkProject"))
    part("p1", "a1", "ses_work", updated: -15, ["type": "reasoning", "time": ["start": ms(-17), "end": ms(-15)]])
    part("p2", "a1", "ses_work", updated: -13, ["type": "text", "time": ["start": ms(-14), "end": ms(-13)]])
    part("p3", "a1", "ses_work", updated: -11, ["type": "tool", "tool": "write", "state": ["status": "completed", "time": ["start": ms(-12), "end": ms(-11)]]])
    message("a2", "ses_work", created: -9, updated: -9, assistant(parent: "u1", created: -9, cwd: "/tmp/WorkProject"))
    part("p4", "a2", "ses_work", updated: -2, ["type": "tool", "tool": "bash", "state": ["status": "running", "time": ["start": ms(-3)]]])
    // A finished turn waiting for the next prompt: 500 tokens over 40 s.
    session("ses_done", directory: "/tmp/DoneProject", updated: -50)
    message("u2", "ses_done", created: -100, updated: -100, user(-100))
    message("b1", "ses_done", created: -90, updated: -50,
            assistant(parent: "u2", created: -90, completed: -50, finish: "stop", output: 500, cwd: "/tmp/DoneProject"))
    part("p5", "b1", "ses_done", updated: -50, ["type": "text", "time": ["start": ms(-60), "end": ms(-50)]])
    // A subagent asking the person a question.
    session("ses_ask", parent: "ses_work", directory: "/tmp/WorkProject", agent: "explore", updated: -25)
    message("u3", "ses_ask", created: -30, updated: -30, user(-30))
    message("c1", "ses_ask", created: -25, updated: -25, assistant(parent: "u3", created: -25, cwd: "/tmp/WorkProject", agent: "explore"))
    part("p6", "c1", "ses_ask", updated: -24, ["type": "tool", "tool": "question", "state": ["status": "running", "time": ["start": ms(-24)]]])
    // A prompt whose body is over the 64 KB cap (a summary with diffs) is never loaded, yet opens a turn.
    session("ses_big", directory: "/tmp/BigProject", updated: -5)
    message("u4", "ses_big", created: -5, updated: -5, user(-5, padding: 70_000))
    // Archived sessions are not listed.
    session("ses_old", directory: "/tmp/OldProject", updated: -1, archived: true)
    message("u5", "ses_old", created: -1, updated: -1, user(-1))
    guard !failed else { return check(false, "OpenCode fixture: SQL failed") }

    let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
    let rows = tracker.sample().filter { $0.source == .opencode }
    func row(_ id: String) -> TokenReading? { rows.first { $0.sessionID == id } }
    let work = row("ses_work")
    check(work?.active == true && work?.activityState == .tool && work?.toolName == "bash" && work?.toolCategory == .command
          && work?.currentTurnStartedAt == now.addingTimeInterval(-20) && work?.currentTurnOutputTokens == 320
          && work?.model == "fixture-model" && work?.project == "WorkProject" && work?.projectPath == "/tmp/WorkProject"
          && work?.context?.usedTokens == 6_000 && work?.isSubagent == false && work?.id.hasSuffix("opencode.db#ses_work") == true
          && work?.title == "Fix flaky login test",
          "OpenCode: a working turn running bash lost its state, turn output, model, project, context or generated title")
    let speed = work?.speedMeasurement
    check(speed?.kind == .requestProcessing && speed?.outputTokens == 320 && speed?.requestDurationMs == 6_000
          && speed.flatMap(\.tokensPerSecond).map { abs($0 - 320.0 / 6) < 0.001 } == true && speed?.model == "fixture-model"
          && speed?.at == now.addingTimeInterval(-10),
          "OpenCode: measured speed is not output + reasoning over created → last generated part")
    let done = row("ses_done")
    check(done?.active == false && done?.activityState == .complete && done?.lastOutputTokens == 500
          && done?.currentTurnStartedAt == nil && done?.currentTurnOutputTokens == nil && done?.project == "DoneProject"
          && done?.measurementAt == now.addingTimeInterval(-50) && done?.speedMeasurement?.tokensPerSecond == 12.5
          && done?.title == nil,
          "OpenCode: a finished turn waiting for input is not complete with its output and speed, or the placeholder title showed")
    let ask = row("ses_ask")
    check(ask?.activityState == .input && ask?.active == true && ask?.toolCategory == .question && ask?.isSubagent == true
          && ask?.parentSessionID == "ses_work" && ask?.agentID == "ses_ask" && ask?.agentRole == "explore" && ask?.title == nil,
          "OpenCode: a subagent asking a question is not waiting for input under its parent, or showed the child placeholder title")
    let big = row("ses_big")
    check(big?.activityState == .working && big?.active == true && big?.currentTurnStartedAt == now.addingTimeInterval(-5)
          && big?.currentTurnOutputTokens == 0 && big?.model == "session-model" && big?.project == "BigProject",
          "OpenCode: an oversized prompt did not open a turn, or the session model was not the fallback")
    check(rows.count == 4 && row("ses_old") == nil
          && rows.flatMap(\.recentOutputs).map(\.tokens).reduce(0, +) == 820,
          "OpenCode: archived sessions listed, or token totals are not the completed messages' output + reasoning")
    check(tracker.isLog(path) && tracker.isLog(folder.appendingPathComponent("opencode-beta.db").path)
          && !tracker.isLog(folder.appendingPathComponent("other.db").path) && !tracker.isLog(path + "-wal"),
          "OpenCode: database file matching is wrong")
    check(TokenProvider.openCodeDatabasePath(home, ["OPENCODE_DB": "custom.db"])?.path == folder.appendingPathComponent("custom.db").path
          && TokenProvider.openCodeDatabasePath(home, ["OPENCODE_DB": ":memory:"]) == nil
          && TokenProvider.openCodeDatabasePath(home, ["OPENCODE_DB": "/tmp/x.db"])?.path == "/tmp/x.db",
          "OpenCode: OPENCODE_DB was not resolved like OpenCode (relative to its data folder; :memory: is no file)")

    // A failed request whose error holds a large gateway page (over the 64 KB body cap) is an assistant message, not a prompt.
    session("ses_err", directory: "/tmp/ErrProject", updated: -3)
    message("u6", "ses_err", created: -8, updated: -8, user(-8))
    message("e1", "ses_err", created: -6, updated: -3,
            json(["role": "assistant", "parentID": "u6", "modelID": "fixture-model", "time": ["created": ms(-6), "completed": ms(-3)],
                  "error": ["name": "APIError", "data": ["responseBody": String(repeating: "<html>", count: 15_000)]]]))
    let errored = tracker.sample().first { $0.sessionID == "ses_err" }
    check(!failed && errored?.activityState == .interrupted && errored?.active == false,
          "OpenCode: an assistant row over 64 KB was read as the person's prompt instead of a failed request")

    // The bash step finishes the turn: the cached message row is replaced because its time_updated moved.
    message("a2", "ses_work", created: -9, updated: -1,
            assistant(parent: "u1", created: -9, completed: -1, finish: "stop", output: 80, cwd: "/tmp/WorkProject"))
    part("p4", "a2", "ses_work", updated: -4, ["type": "tool", "tool": "bash", "state": ["status": "completed", "time": ["start": ms(-3), "end": ms(-4)]]])
    part("p7", "a2", "ses_work", updated: -1, ["type": "text", "time": ["start": ms(-2), "end": ms(-1)]])
    run("UPDATE session SET time_updated = ?, title = 'Renamed: login fix' WHERE id = 'ses_work'", [ms(-1)])
    let finished = tracker.sample().first { $0.sessionID == "ses_work" }
    check(!failed && finished?.activityState == .complete && finished?.active == false && finished?.lastOutputTokens == 400
          && finished?.toolName == nil && finished?.speedMeasurement?.tokensPerSecond == 10
          && finished?.recentOutputs.map(\.tokens) == [320, 80] && finished?.title == "Renamed: login fix",
          "OpenCode: a finished step or the renamed title was not picked up incrementally, or the turn total and speed are wrong")
    check(OpenCodeLog.title("New session - 2026-10-04T05:00:00.000Z") == nil && OpenCodeLog.title("Child session - 2026-10-04T05:00:00.000Z") == nil
          && OpenCodeLog.title("New session - draft") == "New session - draft" && OpenCodeLog.title("   ") == nil,
          "OpenCode: only the exact placeholder (prefix and ISO time) is no title")
}
