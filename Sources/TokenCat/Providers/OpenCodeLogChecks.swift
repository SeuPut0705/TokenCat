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
    let opencodeApp = OpenCodeApp.all[0]
    check(opencodeApp.databasePath(home, ["OPENCODE_DB": "custom.db"])?.path == folder.appendingPathComponent("custom.db").path
          && opencodeApp.databasePath(home, ["OPENCODE_DB": ":memory:"]) == nil
          && opencodeApp.databasePath(home, ["OPENCODE_DB": "/tmp/x.db"])?.path == "/tmp/x.db",
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
    runOpenCodeStoreChecks(root: root, now: now, check: check)
}

/// A fixture database: statements with text, integer or null values; `failed` once one did not run.
private final class OpenCodeFixture {
    private var database: OpaquePointer?
    private(set) var failed = false

    init(_ path: URL) {
        do { try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { failed = true }
        if sqlite3_open(path.path, &database) != SQLITE_OK { failed = true }
    }

    deinit { sqlite3_close(database) }

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
}

/// OpenCode v2 (`session_message` rows, sessions in `session_v2`), a database holding both stores, and the apps built on
/// OpenCode's store (Kilo Code, MiMo Code). Synthetic metadata; every text field says "PRIVATE" and must never surface.
private func runOpenCodeStoreChecks(root: URL, now: Date, check: (Bool, String) -> Void) {
    func ms(_ seconds: TimeInterval) -> Int64 { Int64((now.addingTimeInterval(seconds).timeIntervalSince1970 * 1_000).rounded()) }
    func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
    func leaks(_ rows: [TokenReading]) -> Bool { String(decoding: (try? JSONEncoder().encode(rows)) ?? Data(), as: UTF8.self).contains("PRIVATE") }
    let model: [String: Any] = ["id": "fixture-model", "providerID": "fixture"]
    // v2 rows: `data` without `type` and `id` (they are columns).
    func step(_ created: TimeInterval, completed: TimeInterval? = nil, streamed: TimeInterval? = nil, finish: String? = nil,
              output: Int = 0, reasoning: Int = 0, agent: String = "build", content: [[String: Any]] = []) -> String {
        var time: [String: Any] = ["created": ms(created)]
        if let completed { time["completed"] = ms(completed) }
        if let streamed { time["streamed"] = ms(streamed) }
        var value: [String: Any] = ["agent": agent, "model": model, "time": time, "content": content]
        if let finish {
            value["finish"] = finish
            value["cost"] = 0.01
            value["tokens"] = ["input": 1_000, "output": output, "reasoning": reasoning, "cache": ["read": 5_000, "write": 0]]
        }
        return json(value)
    }
    func prompt(_ created: TimeInterval) -> String { json(["time": ["created": ms(created)], "text": "PRIVATE prompt", "files": [], "agents": []]) }
    func idle(_ created: TimeInterval, _ outcome: String) -> String { json(["time": ["created": ms(created)], "outcome": outcome]) }
    func tool(_ name: String, _ status: String, ran: TimeInterval) -> [String: Any] {
        ["type": "tool", "id": "call-\(name)", "name": name, "state": ["status": status, "input": ["command": "PRIVATE"]],
         "time": ["created": ms(ran - 1), "ran": ms(ran)]]
    }
    let text: [String: Any] = ["type": "text", "text": "PRIVATE reply"]
    func thought(_ created: TimeInterval, _ completed: TimeInterval) -> [String: Any] {
        ["type": "reasoning", "text": "PRIVATE thought", "time": ["created": ms(created), "completed": ms(completed)]]
    }
    // v1 rows, for the stores beside v2 and for Kilo Code and MiMo Code.
    func v1Assistant(parent: String, created: TimeInterval, completed: TimeInterval? = nil, finish: String? = nil, output: Int = 0) -> String {
        var time: [String: Any] = ["created": ms(created)]
        if let completed { time["completed"] = ms(completed) }
        var value: [String: Any] = ["role": "assistant", "parentID": parent, "modelID": "fixture-model", "providerID": "fixture", "agent": "build",
                                    "time": time, "tokens": ["input": 1_000, "output": output, "reasoning": 0, "cache": ["read": 5_000, "write": 0]]]
        if let finish { value["finish"] = finish }
        return json(value)
    }
    func v1User(_ created: TimeInterval) -> String { json(["role": "user", "time": ["created": ms(created)], "agent": "build"]) }
    let v1Tables = ["CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
                    "CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)"]
    let v2Table = "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)"
    let sessionColumns = "(id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT, agent TEXT, model TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER)"
    func session(_ fixture: OpenCodeFixture, _ table: String, _ id: String, parent: String? = nil, directory: String, title: String?,
                 agent: String = "build", updated: TimeInterval) {
        fixture.run("INSERT OR REPLACE INTO \(table) VALUES (?, 'prj', ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
                    [id, parent, id, directory, title, agent, json(model), ms(updated - 60), ms(updated)])
    }
    var seq: Int64 = 0
    func v2(_ fixture: OpenCodeFixture, _ id: String, _ session: String, _ type: String, created: TimeInterval, updated: TimeInterval,
            _ data: String, seq fixed: Int64? = nil) {
        seq += 1
        fixture.run("INSERT OR REPLACE INTO session_message VALUES (?, ?, ?, ?, ?, ?, ?)", [id, session, type, fixed ?? seq, ms(created), ms(updated), data])
    }
    func v1(_ fixture: OpenCodeFixture, _ id: String, _ session: String, created: TimeInterval, updated: TimeInterval, _ data: String) {
        fixture.run("INSERT OR REPLACE INTO message VALUES (?, ?, ?, ?, ?)", [id, session, ms(created), ms(updated), data])
    }

    // v2 only, as OpenCode's v2 builds write it.
    let v2Home = root.appendingPathComponent("opencode-v2-home")
    let store = OpenCodeFixture(v2Home.appendingPathComponent(".local/share/opencode/opencode.db"))
    store.run("CREATE TABLE session_v2 \(sessionColumns)")
    store.run(v2Table)
    // A working turn: a step that streamed for 6 s (320 tokens, 53.3 tok/s) and called write, then a step running bash.
    session(store, "session_v2", "ses_v2work", directory: "/tmp/WorkV2", title: "Fix flaky\nlogin test", updated: -20)
    v2(store, "w1", "ses_v2work", "user", created: -20, updated: -20, prompt(-20))
    v2(store, "w2", "ses_v2work", "assistant", created: -18, updated: -10,
       step(-18, completed: -10, streamed: -12, finish: "tool-calls", output: 300, reasoning: 20,
            content: [thought(-17, -15), text, tool("write", "completed", ran: -12)]))
    let w3 = seq + 1
    v2(store, "w3", "ses_v2work", "assistant", created: -9, updated: -2, step(-9, content: [tool("bash", "running", ran: -3)]))
    // A subagent asking the person a question.
    session(store, "session_v2", "ses_v2ask", parent: "ses_v2work", directory: "/tmp/WorkV2", title: nil, agent: "explore", updated: -30)
    v2(store, "q1", "ses_v2ask", "user", created: -30, updated: -30, prompt(-30))
    v2(store, "q2", "ses_v2ask", "assistant", created: -25, updated: -24, step(-25, agent: "explore", content: [tool("question", "running", ran: -24)]))
    // A turn an idle marker ended (500 tokens over a 40 s step that ran no tool); the session row was last written 2 h ago.
    session(store, "session_v2", "ses_v2done", directory: "/tmp/DoneV2", title: nil, updated: -7_200)
    v2(store, "d1", "ses_v2done", "user", created: -100, updated: -100, prompt(-100))
    v2(store, "d2", "ses_v2done", "assistant", created: -90, updated: -50, step(-90, completed: -50, finish: "stop", output: 500, content: [text]))
    v2(store, "d3", "ses_v2done", "idle", created: -49, updated: -49, idle(-49, "succeeded"))
    // A turn the person interrupted between steps.
    session(store, "session_v2", "ses_v2stop", directory: "/tmp/StopV2", title: nil, updated: -40)
    v2(store, "s1", "ses_v2stop", "user", created: -40, updated: -40, prompt(-40))
    v2(store, "s2", "ses_v2stop", "assistant", created: -38, updated: -35, step(-38, completed: -35, finish: "tool-calls", output: 10, content: [text]))
    v2(store, "s3", "ses_v2stop", "idle", created: -34, updated: -34, idle(-34, "interrupted"))
    guard !store.failed else { return check(false, "OpenCode v2 fixture: SQL failed") }

    let tracker = TokenTracker(homeDirectory: v2Home, environment: [:], now: { now }, discoveryInterval: 0)
    let rows = tracker.sample().filter { $0.source == .opencode }
    func row(_ id: String, in rows: [TokenReading]) -> TokenReading? { rows.first { $0.sessionID == id } }
    let work = row("ses_v2work", in: rows)
    check(work?.active == true && work?.activityState == .tool && work?.toolName == "bash" && work?.toolCategory == .command
          && work?.currentTurnStartedAt == now.addingTimeInterval(-20) && work?.currentTurnOutputTokens == 320
          && work?.model == "fixture-model" && work?.project == "WorkV2" && work?.context?.usedTokens == 6_000
          && work?.title == "Fix flaky login test" && work?.clientName == nil && work?.isSubagent == false
          && work?.speedMeasurement?.requestDurationMs == 6_000 && work?.speedMeasurement?.outputTokens == 320
          && work?.speedMeasurement?.at == now.addingTimeInterval(-10),
          "OpenCode v2: a working turn running bash lost its state, turn output, model, project, context, title or streamed speed")
    let ask = row("ses_v2ask", in: rows)
    check(ask?.activityState == .input && ask?.active == true && ask?.toolCategory == .question && ask?.isSubagent == true
          && ask?.parentSessionID == "ses_v2work" && ask?.agentRole == "explore" && ask?.title == nil,
          "OpenCode v2: a subagent asking a question is not waiting for input under its parent")
    let done = row("ses_v2done", in: rows)
    let stopped = row("ses_v2stop", in: rows)
    check(done?.activityState == .complete && done?.active == false && done?.lastOutputTokens == 500
          && done?.measurementAt == now.addingTimeInterval(-50) && done?.speedMeasurement?.tokensPerSecond == 12.5
          && done?.project == "DoneV2" && done?.title == nil
          && stopped?.activityState == .interrupted && stopped?.active == false && stopped?.lastOutputTokens == nil,
          "OpenCode v2: a turn ended by an idle marker is not complete with its output and speed, or an interrupted one is not interrupted")
    check(rows.count == 4 && !leaks(rows) && rows.flatMap(\.recentOutputs).map(\.tokens).reduce(0, +) == 830,
          "OpenCode v2: rows leaked text, or sessions were missed or listed twice")

    // The bash step ends the turn (its stream ended at -1 s: 80 tokens over 8 s); a prompt reopens the finished session
    // and a second one sent mid-turn joins that turn. Neither session row is written.
    v2(store, "w3", "ses_v2work", "assistant", created: -9, updated: -1,
       step(-9, completed: -1, streamed: -1, finish: "stop", output: 80, content: [tool("bash", "completed", ran: -3), text]), seq: w3)
    v2(store, "d4", "ses_v2done", "user", created: -3, updated: -3, prompt(-3))
    v2(store, "d5", "ses_v2done", "assistant", created: -2, updated: -2, step(-2, content: [text]))
    v2(store, "d6", "ses_v2done", "user", created: -1, updated: -1, prompt(-1))
    let next = tracker.sample().filter { $0.source == .opencode }
    let finished = row("ses_v2work", in: next)
    check(!store.failed && finished?.activityState == .complete && finished?.active == false && finished?.lastOutputTokens == 400
          && finished?.toolName == nil && finished?.speedMeasurement?.tokensPerSecond == 10 && finished?.recentOutputs.map(\.tokens) == [320, 80],
          "OpenCode v2: a finished step was not picked up incrementally, or its turn total and streamed speed are wrong")
    let reopened = row("ses_v2done", in: next)
    check(reopened?.activityState == .working && reopened?.active == true && reopened?.currentTurnStartedAt == now.addingTimeInterval(-3)
          && reopened?.currentTurnOutputTokens == 0,
          "OpenCode v2: messages written without moving the session's time_updated were missed, or a prompt sent mid-turn did not join it")

    // Both stores: a database migrated to v2 keeps its v1 tables, and its sessions are copied under the same ids.
    let bothHome = root.appendingPathComponent("opencode-both-home")
    let both = OpenCodeFixture(bothHome.appendingPathComponent(".local/share/opencode/opencode.db"))
    both.run("CREATE TABLE session \(sessionColumns)")
    both.run("CREATE TABLE session_v2 \(sessionColumns)")
    v1Tables.forEach { both.run($0) }
    both.run(v2Table)
    session(both, "session", "ses_both", directory: "/tmp/BothProject", title: "PRIVATE old title", updated: -100)
    session(both, "session_v2", "ses_both", directory: "/tmp/BothProject", title: "Migrated title", updated: -5)
    v1(both, "m1", "ses_both", created: -120, updated: -120, v1User(-120))
    v1(both, "m2", "ses_both", created: -110, updated: -100, v1Assistant(parent: "m1", created: -110, completed: -100, finish: "stop", output: 111))
    v2(both, "m1", "ses_both", "user", created: -120, updated: -120, prompt(-120))
    v2(both, "m2", "ses_both", "assistant", created: -110, updated: -100, step(-110, completed: -100, finish: "stop", output: 111, content: [text]))
    v2(both, "m3", "ses_both", "user", created: -10, updated: -10, prompt(-10))
    v2(both, "m4", "ses_both", "assistant", created: -8, updated: -5, step(-8, completed: -5, finish: "stop", output: 222, content: [text]))
    // A session an older (v1) build kept writing after the migration copied it.
    session(both, "session", "ses_v1newer", directory: "/tmp/NewerV1", title: nil, updated: -7)
    v2(both, "n1", "ses_v1newer", "user", created: -200, updated: -200, prompt(-200))
    v2(both, "n2", "ses_v1newer", "assistant", created: -190, updated: -180, step(-190, completed: -180, finish: "stop", output: 50, content: [text]))
    v1(both, "n1", "ses_v1newer", created: -200, updated: -200, v1User(-200))
    v1(both, "n2", "ses_v1newer", created: -190, updated: -180, v1Assistant(parent: "n1", created: -190, completed: -180, finish: "stop", output: 50))
    v1(both, "n3", "ses_v1newer", created: -8, updated: -8, v1User(-8))
    v1(both, "n4", "ses_v1newer", created: -7, updated: -7, v1Assistant(parent: "n3", created: -7))
    both.run("INSERT INTO part VALUES ('np', 'n4', 'ses_v1newer', ?, ?, ?)",
             [ms(-6), ms(-6), json(["type": "tool", "tool": "bash", "state": ["status": "running", "input": ["command": "PRIVATE"], "time": ["start": ms(-6)]]])])
    guard !both.failed else { return check(false, "OpenCode both-stores fixture: SQL failed") }
    let bothRows = TokenTracker(homeDirectory: bothHome, environment: [:], now: { now }, discoveryInterval: 0).sample().filter { $0.source == .opencode }
    let merged = row("ses_both", in: bothRows)
    check(bothRows.filter { $0.sessionID == "ses_both" }.count == 1 && merged?.lastOutputTokens == 222 && merged?.activityState == .complete
          && merged?.recentOutputs.map(\.tokens).reduce(0, +) == 333 && merged?.title == "Migrated title" && !leaks(bothRows),
          "OpenCode: a session in both stores was counted twice or not read from the store with the newest message, or its v2 title was lost")
    let newer = row("ses_v1newer", in: bothRows)
    check(bothRows.count == 2 && newer?.activityState == .tool && newer?.toolName == "bash" && newer?.currentTurnStartedAt == now.addingTimeInterval(-8)
          && newer?.currentTurnOutputTokens == 0,
          "OpenCode: a session whose v1 messages are newer than its v2 copy was not read from v1")

    // Kilo Code's store (OpenCode's v1 schema) and MiMo Code's (no session agent or model, a title source, subagent threads
    // in the session's own message table).
    let appsHome = root.appendingPathComponent("opencode-apps-home")
    let data = appsHome.appendingPathComponent(".local/share")
    let kilo = OpenCodeFixture(data.appendingPathComponent("kilo/kilo.db"))
    kilo.run("CREATE TABLE session \(sessionColumns)")
    v1Tables.forEach { kilo.run($0) }
    session(kilo, "session", "ses_kilo", directory: "/tmp/KiloProject", title: "Kilo task", updated: -9)
    v1(kilo, "k1", "ses_kilo", created: -10, updated: -10, v1User(-10))
    v1(kilo, "k2", "ses_kilo", created: -9, updated: -9, v1Assistant(parent: "k1", created: -9))
    kilo.run("INSERT INTO part VALUES ('kp', 'k2', 'ses_kilo', ?, ?, ?)",
             [ms(-8), ms(-8), json(["type": "tool", "tool": "grep", "state": ["status": "running", "input": ["pattern": "PRIVATE"], "time": ["start": ms(-8)]]])])
    let mimo = OpenCodeFixture(data.appendingPathComponent("mimocode/mimocode.db"))
    mimo.run("CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL, title_source TEXT NOT NULL DEFAULT 'user', version TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER)")
    mimo.run("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, agent_id TEXT NOT NULL DEFAULT 'main', time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)")
    mimo.run(v1Tables[1])
    mimo.run("INSERT INTO session VALUES ('ses_mimo', 'prj', NULL, 'mimo', '/tmp/MimoProject', 'PRIVATE first prompt', 'fallback', '0.1.14', ?, ?, NULL)", [ms(-30), ms(-4)])
    mimo.run("INSERT INTO session VALUES ('ses_mimo_named', 'prj', NULL, 'named', '/tmp/MimoProject', 'Generated title', 'generated', '0.1.14', ?, ?, NULL)", [ms(-40), ms(-30)])
    mimo.run("INSERT INTO message VALUES ('x1', 'ses_mimo', 'main', ?, ?, ?)", [ms(-20), ms(-20), v1User(-20)])
    mimo.run("INSERT INTO message VALUES ('x2', 'ses_mimo', 'main', ?, ?, ?)",
             [ms(-18), ms(-15), v1Assistant(parent: "x1", created: -18, completed: -15, finish: "stop", output: 70)])
    mimo.run("INSERT INTO message VALUES ('x3', 'ses_mimo', 'explore-1', ?, ?, ?)", [ms(-5), ms(-4), v1Assistant(parent: "x1", created: -5)])
    mimo.run("INSERT INTO message VALUES ('y1', 'ses_mimo_named', 'main', ?, ?, ?)", [ms(-30), ms(-30), v1User(-30)])
    guard !kilo.failed && !mimo.failed else { return check(false, "OpenCode apps fixture: SQL failed") }
    let appsTracker = TokenTracker(homeDirectory: appsHome, environment: [:], now: { now }, discoveryInterval: 0)
    let appRows = appsTracker.sample().filter { $0.source == .opencode }
    let kiloRow = row("ses_kilo", in: appRows)
    check(kiloRow?.clientName == "Kilo Code" && kiloRow?.activityState == .tool && kiloRow?.toolName == "grep" && kiloRow?.toolCategory == .file
          && kiloRow?.id.hasSuffix("kilo/kilo.db#ses_kilo") == true && kiloRow?.title == "Kilo task" && kiloRow?.project == "KiloProject"
          && kiloRow?.model == "fixture-model",
          "Kilo Code: its kilo.db was not read as an OpenCode store labelled Kilo Code")
    let mimoRow = row("ses_mimo", in: appRows)
    let named = row("ses_mimo_named", in: appRows)
    check(mimoRow?.clientName == "MiMo Code" && mimoRow?.activityState == .complete && mimoRow?.lastOutputTokens == 70
          && mimoRow?.model == "fixture-model" && mimoRow?.title == nil && named?.title == "Generated title" && named?.clientName == "MiMo Code"
          && named?.activityState == .working && appRows.count == 3 && !leaks(appRows),
          "MiMo Code: a subagent thread changed the main turn, a fallback title showed, or the rows were not labelled MiMo Code")

    let opencodeRoots = TokenProvider.all.first { $0.source == .opencode }?.roots(appsHome, ["MIMOCODE_HOME": "/tmp/mimo-home", "KILO_DB": "/tmp/kilo-x/k.db"]).map(\.path) ?? []
    let (opencodeApp, kiloApp, mimoApp) = (OpenCodeApp.all[0], OpenCodeApp.all[1], OpenCodeApp.all[2])
    check(appsTracker.isLog(data.appendingPathComponent("kilo/kilo-beta.db").path) && appsTracker.isLog(data.appendingPathComponent("mimocode/mimocode-dev.db").path)
          && OpenCodeApp.of(data.appendingPathComponent("kilo/opencode-dev.db").path)?.client == "Kilo Code"
          && OpenCodeApp.of(data.appendingPathComponent("opencode/opencode-dev.db").path).map { $0.client == nil } == true
          && !appsTracker.isLog(data.appendingPathComponent("kilo/kilo.json").path)
          && kiloApp.databasePath(appsHome, ["KILO_DB": "custom.db"])?.path == data.appendingPathComponent("kilo/custom.db").path
          && kiloApp.databasePath(appsHome, ["KILO_DB": ":memory:"]) == nil
          && mimoApp.databasePath(appsHome, ["MIMOCODE_HOME": "/tmp/mimo-home", "MIMOCODE_DB": "x.db"])?.path == "/tmp/mimo-home/data/x.db"
          && opencodeApp.dataFolder(appsHome, ["XDG_DATA_HOME": "/tmp/xdg"]).path == "/tmp/xdg/opencode"
          && opencodeRoots == [data.appendingPathComponent("opencode").path, "/tmp/kilo-x", data.appendingPathComponent("kilo").path, "/tmp/mimo-home/data"],
          "OpenCode apps: Kilo Code or MiMo Code database files, their variables or data folders are not resolved like the apps")
}
