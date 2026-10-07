import Foundation
import SQLite3

/// OpenClaw fixtures for both storage generations (synthetic metadata, no transcript text): a running tool turn, a finished
/// turn with its output, transcript-only rows, `endTurn: false`, waiting for the person, model, project, titles, a subagent
/// under its parent, compressed rows and the entry total that settles them. Run from `runTrackerChecks`.
/// Shapes follow openclaw/openclaw: `src/state/openclaw-agent-schema.sql` (tables, a subset of their columns),
/// `src/config/sessions/transcript-payload.ts` and `session-model-context-projection.ts` (`navigation_json` of a compressed
/// row), `packages/llm-core/src/types.ts` (messages), `src/config/sessions/types.ts` (session entry fields).
func runOpenClawLogChecks(root: URL, check: (Bool, String) -> Void) {
    let start = ISO8601DateFormatter().date(from: "2026-10-04T08:00:00Z")!
    func iso(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: start.addingTimeInterval(seconds))
    }
    func ms(_ seconds: TimeInterval) -> Int64 { Int64((start.addingTimeInterval(seconds).timeIntervalSince1970 * 1_000).rounded()) }
    func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
    func header(_ id: String, cwd: String) -> [String: Any] {
        ["type": "session", "version": 3, "id": id, "timestamp": iso(0), "cwd": cwd]
    }
    func user(_ id: String, _ seconds: TimeInterval) -> [String: Any] {
        ["type": "message", "id": id, "timestamp": iso(seconds), "message": ["role": "user", "content": "PRIVATE_PROMPT", "timestamp": ms(seconds)]]
    }
    func assistant(_ id: String, _ seconds: TimeInterval, output: Int, stop: String, tool: (id: String, name: String)? = nil,
                   extra: [String: Any] = [:]) -> [String: Any] {
        var content: [[String: Any]] = [["type": "thinking", "thinking": "PRIVATE_THOUGHT"], ["type": "text", "text": "PRIVATE_REPLY"]]
        if let tool { content.append(["type": "toolCall", "id": tool.id, "name": tool.name, "arguments": ["command": "PRIVATE_CMD"]]) }
        var message: [String: Any] = ["role": "assistant", "content": content, "api": "anthropic-messages", "provider": "anthropic",
                                      "model": "claude-fixture", "stopReason": stop, "timestamp": ms(seconds - 2),
                                      "usage": ["input": 10, "output": output, "cacheRead": 5_000, "cacheWrite": 990, "totalTokens": 6_000 + output]]
        message.merge(extra) { $1 }
        return ["type": "message", "id": id, "timestamp": iso(seconds), "message": message]
    }
    func toolResult(_ id: String, _ seconds: TimeInterval, call: String) -> [String: Any] {
        ["type": "message", "id": id, "timestamp": iso(seconds),
         "message": ["role": "toolResult", "toolCallId": call, "toolName": "exec", "content": [["type": "text", "text": "PRIVATE_OUT"]],
                     "isError": false, "timestamp": ms(seconds)]]
    }
    /// What OpenClaw writes as transcript bookkeeping after a channel delivery: no model output.
    func mirror(_ id: String, _ seconds: TimeInterval) -> [String: Any] {
        ["type": "message", "id": id, "timestamp": iso(seconds),
         "message": ["role": "assistant", "content": [["type": "text", "text": "PRIVATE_DELIVERED"]], "api": "openclaw-transcript",
                     "provider": "openclaw", "model": "delivery-mirror", "stopReason": "stop", "timestamp": ms(seconds),
                     "usage": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0]]]
    }
    func lines(_ records: [[String: Any]]) -> Data { Data(records.map { json($0) + "\n" }.joined().utf8) }
    func append(_ url: URL, _ records: [[String: Any]]) throws {
        guard let handle = try? FileHandle(forWritingTo: url) else { return try lines(records).write(to: url) }
        try handle.seekToEnd()
        try handle.write(contentsOf: lines(records))
        try handle.close()
    }
    func encoded(_ readings: [TokenReading]) -> String { String(decoding: (try? JSONEncoder().encode(readings)) ?? Data(), as: UTF8.self) }

    // JSONL generation: sessions/<sessionId>.jsonl with the sessions.json index.
    do {
        let home = root.appendingPathComponent("openclaw-legacy-home")
        let sessions = home.appendingPathComponent(".openclaw/agents/main/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try json([
            "agent:main:main": ["sessionId": "oc-main", "updatedAt": ms(1), "label": "Renamed OpenClaw chat", "totalTokens": 1,
                                "totalTokensFresh": true, "contextTokens": 100_000, "contextTokensSource": "runtime-configured"],
            "agent:main:subagent:7f3c": ["sessionId": "oc-sub", "updatedAt": ms(20), "spawnedBy": "agent:main:main", "label": "researcher"],
            "agent:main:whatsapp:direct:PRIVATE_PEER": ["sessionId": "oc-ask", "updatedAt": ms(1), "origin": ["label": "PRIVATE_CONTACT"]],
        ]).write(to: sessions.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)
        let main = sessions.appendingPathComponent("oc-main.jsonl")
        try append(main, [header("oc-main", cwd: "/tmp/Fixture/ClawProject"),
                          ["type": "model_change", "id": "m1", "timestamp": iso(0), "provider": "anthropic", "modelId": "claude-fixture"],
                          user("u1", 10), assistant("a1", 20, output: 40, stop: "toolUse", tool: ("call-1", "exec"))])
        try append(sessions.appendingPathComponent("oc-sub.jsonl"), [header("oc-sub", cwd: "/tmp/Fixture/ClawProject"), user("s1", 15),
                                                                     assistant("s2", 18, output: 12, stop: "stop")])
        try append(sessions.appendingPathComponent("oc-ask.jsonl"), [header("oc-ask", cwd: "/tmp/Fixture/AskProject"), user("q1", 30),
                                                                     assistant("q2", 35, output: 3, stop: "toolUse", tool: ("call-q", "ask_user"))])
        var now = start.addingTimeInterval(60)
        let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
        var rows = tracker.sample()
        var row = rows.first { $0.sessionID == "oc-main" }
        check(row?.source == .openclaw && row?.active == true && row?.activityState == .tool && row?.toolName == "exec"
              && row?.toolCategory == .command && row?.currentTurnStartedAt == start.addingTimeInterval(10)
              && row?.currentTurnOutputTokens == 40 && row?.model == "claude-fixture" && row?.project == "ClawProject"
              && row?.projectPath == "/tmp/Fixture/ClawProject" && row?.title == "Renamed OpenClaw chat"
              && row?.context?.usedTokens == 6_000 && row?.context?.windowTokens == 100_000 && row?.recentOutputs.map(\.tokens) == [40]
              && row?.isSubagent == false && row?.speedMeasurement == nil,
              "OpenClaw JSONL: a reply calling a tool was not a running tool turn with its output, model, context, project and renamed title")
        let sub = rows.first { $0.sessionID == "oc-sub" }
        check(sub?.isSubagent == true && sub?.parentSessionID == "oc-main" && sub?.agentID == "oc-sub" && sub?.agentRole == "researcher"
              && sub?.activityState == .complete && sub?.lastOutputTokens == 12 && sub?.title == nil,
              "OpenClaw JSONL: a spawned session was not a subagent under its parent, named by its label, with its output")
        let ask = rows.first { $0.sessionID == "oc-ask" }
        check(ask?.activityState == .input && ask?.active == true && ask?.toolCategory == .question && ask?.title == nil,
              "OpenClaw JSONL: ask_user did not wait for the person, or a channel session without a title got one")

        try append(main, [toolResult("t1", 30, call: "call-1"), assistant("a2", 45, output: 60, stop: "stop"), mirror("d1", 46)])
        now = start.addingTimeInterval(50)
        rows = tracker.sample()
        row = rows.first { $0.sessionID == "oc-main" }
        check(row?.active == false && row?.activityState == .complete && row?.lastOutputTokens == 100 && row?.currentTurnOutputTokens == nil
              && row?.toolName == nil && row?.recentOutputs.map(\.tokens) == [40, 60] && row?.measurementAt == start.addingTimeInterval(45)
              && rows.count == 3 && !encoded(rows).contains("PRIVATE"),
              "OpenClaw JSONL: a stop reply did not complete the turn with its whole output, a delivery mirror reopened it, or text leaked")
        let tailOnly = TokenTracker(homeDirectory: home, environment: [:], now: { now }, initialTailBytes: 900).sample()
            .first { $0.id.hasSuffix("oc-main.jsonl") }
        check(tailOnly?.sessionID == "oc-main" && tailOnly?.project == "ClawProject" && tailOnly?.activityState == .complete,
              "OpenClaw JSONL: the session header was lost when the first read started mid-file")
        let agents = home.appendingPathComponent(".openclaw/agents/main")
        check(tracker.isLog(main.path) && tracker.isLog(agents.appendingPathComponent("agent/openclaw-agent.sqlite").path)
              && tracker.wakesSampling(agents.appendingPathComponent("agent/openclaw-agent.sqlite-wal").path)
              && !tracker.isLog(main.path + ".reset.2026-10-04T08-00-00.000Z")
              && !tracker.isLog(agents.appendingPathComponent("sessions/sessions.json").path)
              && !tracker.isLog(agents.appendingPathComponent("agent/incognito-openclaw-agent.sqlite").path)
              && !tracker.isLog(agents.appendingPathComponent("agent/codex-home/sessions/2026/10/04/rollout-x.jsonl").path)
              && !tracker.isLog(agents.appendingPathComponent("session-sqlite-import-archive/k.oc-main.jsonl").path),
              "OpenClaw: transcript, database or archive path matching is wrong")
        let roots = TokenProvider.all.first { $0.source == .openclaw }?.roots(home, ["OPENCLAW_STATE_DIR": "/tmp/claw-state",
                                                                                     "OPENCLAW_PROFILE": "work"]).map(\.path) ?? []
        check(roots == ["/tmp/claw-state/agents", home.path + "/.openclaw-work/agents", home.path + "/.openclaw/agents",
                        home.path + "/.openclaw/agents", home.path + "/.clawdbot/agents", home.path + "/.moltbot/agents"],
              "OpenClaw: OPENCLAW_STATE_DIR, a named profile or the legacy state folders are not roots")
    } catch {
        check(false, "OpenClaw JSONL fixture error: \(error.localizedDescription)")
    }

    // SQLite generation: agent/openclaw-agent.sqlite.
    let home = root.appendingPathComponent("openclaw-db-home")
    let folder = home.appendingPathComponent(".openclaw/agents/main/agent")
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
        return check(false, "OpenClaw fixture error: \(error.localizedDescription)")
    }
    guard sqlite3_open(folder.appendingPathComponent("openclaw-agent.sqlite").path, &database) == SQLITE_OK else {
        return check(false, "OpenClaw fixture: database not created")
    }
    var failed = false
    func run(_ sql: String, _ values: [Any?] = []) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { failed = true; return }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            switch value {
            case let text as String: sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            case let number as Int64: sqlite3_bind_int64(statement, Int32(index + 1), number)
            case let blob as Data: _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32(blob.count), transient) }
            default: sqlite3_bind_null(statement, Int32(index + 1))
            }
        }
        if sqlite3_step(statement) != SQLITE_DONE { failed = true }
    }
    run("""
        CREATE TABLE session_nodes (session_key TEXT NOT NULL PRIMARY KEY, current_session_id TEXT NOT NULL, entry_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL, label TEXT, display_name TEXT)
        """)
    run("""
        CREATE TABLE session_windows (session_id TEXT NOT NULL PRIMARY KEY, session_key TEXT NOT NULL, previous_session_id TEXT,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, transcript_updated_at INTEGER DEFAULT NULL, model_provider TEXT,
            model TEXT, agent_harness_id TEXT)
        """)
    run("""
        CREATE TABLE transcript_events (session_id TEXT NOT NULL, seq INTEGER NOT NULL, event_json TEXT, created_at INTEGER NOT NULL,
            event_zstd BLOB, event_utf8_bytes INTEGER, navigation_json TEXT, PRIMARY KEY (session_id, seq))
        """)
    var seqs: [String: Int64] = [:]
    func session(_ id: String, key: String, entry: [String: Any], updated: TimeInterval) {
        run("INSERT OR REPLACE INTO session_nodes VALUES (?, ?, ?, ?, NULL, NULL)", [key, id, json(entry), ms(updated)])
        run("INSERT OR REPLACE INTO session_windows VALUES (?, ?, NULL, ?, ?, ?, 'anthropic', 'window-model', 'pi')",
            [id, key, ms(0), ms(updated), ms(updated)])
    }
    func touch(_ id: String, _ seconds: TimeInterval) {
        run("UPDATE session_windows SET updated_at = ?, transcript_updated_at = ? WHERE session_id = ?", [ms(seconds), ms(seconds), id])
    }
    func event(_ id: String, _ record: [String: Any], at seconds: TimeInterval) {
        let seq = seqs[id, default: -1] + 1
        seqs[id] = seq
        run("INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES (?, ?, ?, ?)", [id, seq, json(record), ms(seconds)])
        touch(id, seconds)
    }
    /// A row stored as a zstd frame: the body is opaque here, and only the navigation facts are plain.
    func compressed(_ id: String, _ seconds: TimeInterval, message: [String: Any], idempotencyKey: String? = nil) {
        let seq = seqs[id, default: -1] + 1
        seqs[id] = seq
        let entry: [String: Any] = ["type": "message", "id": "z\(seq)", "parentId": "p\(seq)", "timestamp": iso(seconds)]
        var navigationMessage: [String: Any] = ["role": message["role"] ?? "assistant"]
        if let idempotencyKey { navigationMessage["idempotencyKey"] = idempotencyKey }
        var model = entry
        model["message"] = message.merging(["command": "", "output": "", "providerReplay": ["type": NSNull()], "details": ["synthetic": false]]) { $1 }
        let navigation: [String: Any] = [
            "version": 1, "report": ["kind": "canonical", "hasParentId": true, "entry": entry],
            "navigation": entry.merging(["message": navigationMessage]) { $1 }, "reset": entry, "model": model,
            "modelBytes": 2_048, "modelWithoutCheckpointBytes": 2_048, "withoutCustomDataBytes": 2_048,
        ]
        run("INSERT INTO transcript_events VALUES (?, ?, NULL, ?, ?, 4096, ?)",
            [id, seq, ms(seconds), Data("PRIVATE zstd frame".utf8), json(navigation)])
        touch(id, seconds)
    }
    // A running turn: a readable reply ran exec, then compressed rows finished it and called read.
    session("ses-work", key: "agent:main:main", entry: ["sessionId": "ses-work", "updatedAt": ms(5), "displayName": "Generated DB title",
                                                        "outputTokens": 999, "totalTokens": 4_000, "totalTokensFresh": true,
                                                        "contextTokens": 200_000, "contextTokensSource": "runtime", "model": "entry-model"], updated: 5)
    event("ses-work", header("ses-work", cwd: "/tmp/Fixture/ClawDb"), at: 0)
    event("ses-work", ["type": "model_change", "id": "m1", "parentId": NSNull(), "timestamp": iso(0), "provider": "anthropic",
                       "modelId": "claude-fixture"], at: 0)
    event("ses-work", user("u1", 10), at: 10)
    event("ses-work", assistant("a1", 20, output: 30, stop: "toolUse", tool: ("call-1", "exec")), at: 20)
    compressed("ses-work", 30, message: ["role": "toolResult", "toolCallId": "call-1", "toolName": "exec", "isError": false,
                                         "timestamp": ms(30), "content": []])
    compressed("ses-work", 40, message: ["role": "assistant", "provider": "anthropic", "model": "claude-fixture", "timestamp": ms(32),
                                         "stopReason": "toolUse", "content": [["type": "toolCall", "id": "call-2", "name": "read"]]])
    // A subagent: its parent is the spawning key's current session.
    session("ses-sub", key: "agent:main:subagent:7f3c", entry: ["sessionId": "ses-sub", "updatedAt": ms(26), "label": "fixer",
                                                                "spawnedBy": "agent:main:main", "outputTokens": 9], updated: 26)
    event("ses-sub", header("ses-sub", cwd: "/tmp/Fixture/ClawDb"), at: 0)
    event("ses-sub", user("s1", 15), at: 15)
    event("ses-sub", assistant("s2", 25, output: 9, stop: "stop"), at: 25)
    // A question for the person on a channel session (its key names a peer, never shown).
    session("ses-ask", key: "agent:main:telegram:direct:PRIVATE_PEER", entry: ["sessionId": "ses-ask", "updatedAt": ms(1)], updated: 35)
    event("ses-ask", header("ses-ask", cwd: "/tmp/Fixture/AskProject"), at: 0)
    event("ses-ask", user("q1", 30), at: 30)
    event("ses-ask", assistant("q2", 35, output: 4, stop: "toolUse", tool: ("call-q", "ask_user")), at: 35)
    // A finished cron turn: `endTurn: false` asked for another inference; a delivery mirror followed the answer.
    session("ses-done", key: "agent:main:cron:job-1", entry: ["sessionId": "ses-done", "updatedAt": ms(7)], updated: 7)
    event("ses-done", header("ses-done", cwd: "/tmp/Fixture/CronProject"), at: 0)
    event("ses-done", user("c1", 1), at: 1)
    event("ses-done", assistant("c2", 3, output: 5, stop: "stop", extra: ["endTurn": false]), at: 3)
    event("ses-done", assistant("c3", 5, output: 45, stop: "stop"), at: 5)
    event("ses-done", mirror("c4", 6), at: 6)
    // A Codex app-server turn: the mirrored reply carries the last response's usage; the entry holds the run's total.
    session("ses-codex", key: "agent:main:codex", entry: ["sessionId": "ses-codex", "updatedAt": ms(9), "outputTokens": 300], updated: 9)
    event("ses-codex", header("ses-codex", cwd: "/tmp/Fixture/CodexProject"), at: 0)
    event("ses-codex", user("x1", 2), at: 2)
    event("ses-codex", assistant("x2", 8, output: 7, stop: "stop", extra: ["idempotencyKey": "codex-app-server:t1:u1:assistant"]), at: 8)
    guard !failed else { return check(false, "OpenClaw fixture: SQL failed") }

    var now = start.addingTimeInterval(60)
    let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
    var rows = tracker.sample().filter { $0.source == .openclaw }
    func row(_ id: String) -> TokenReading? { rows.first { $0.sessionID == id } }
    var work = row("ses-work")
    check(work?.active == true && work?.activityState == .tool && work?.toolName == "read" && work?.toolCategory == .file
          && work?.currentTurnStartedAt == start.addingTimeInterval(10) && work?.currentTurnOutputTokens == nil
          && work?.recentOutputs.map(\.tokens) == [30] && work?.model == "claude-fixture" && work?.project == "ClawDb"
          && work?.projectPath == "/tmp/Fixture/ClawDb" && work?.title == "Generated DB title" && work?.context?.usedTokens == 6_000
          && work?.context?.windowTokens == 200_000 && work?.lastOutputTokens == nil
          && work?.id.hasSuffix("openclaw-agent.sqlite#ses-work") == true,
          "OpenClaw SQLite: compressed rows did not keep the tool turn, or its output was counted as whole without readable usage")
    let sub = row("ses-sub")
    check(sub?.isSubagent == true && sub?.parentSessionID == "ses-work" && sub?.agentID == "ses-sub" && sub?.agentRole == "fixer"
          && sub?.activityState == .complete && sub?.lastOutputTokens == 9 && sub?.title == nil,
          "OpenClaw SQLite: a spawned session was not grouped under the spawning key's current session")
    let ask = row("ses-ask")
    check(ask?.activityState == .input && ask?.active == true && ask?.toolName == "ask_user" && ask?.title == nil
          && ask?.project == "AskProject" && ask?.isSubagent == false,
          "OpenClaw SQLite: ask_user did not wait for the person")
    let done = row("ses-done")
    check(done?.activityState == .complete && done?.active == false && done?.lastOutputTokens == 50
          && done?.recentOutputs.map(\.tokens) == [5, 45] && done?.measurementAt == start.addingTimeInterval(5) && done?.model == "claude-fixture",
          "OpenClaw SQLite: endTurn false ended the turn, or a delivery mirror counted as a reply")
    let codex = row("ses-codex")
    check(codex?.lastOutputTokens == 300 && codex?.recentOutputs.map(\.tokens) == [7, 293] && codex?.activityState == .complete,
          "OpenClaw SQLite: a Codex app-server mirror was not settled by the session entry's output total")
    check(rows.count == 5 && !encoded(rows).contains("PRIVATE"),
          "OpenClaw SQLite: a session is missing, or a session key, body or text leaked into a reading")

    // The turn ends in compressed rows; its output is unknown until the entry written after the run settles it.
    compressed("ses-work", 50, message: ["role": "toolResult", "toolCallId": "call-2", "toolName": "read", "isError": false,
                                         "timestamp": ms(50), "content": []])
    compressed("ses-work", 70, message: ["role": "assistant", "provider": "anthropic", "model": "claude-fixture", "timestamp": ms(62),
                                         "stopReason": "stop", "content": []])
    now = start.addingTimeInterval(80)
    rows = tracker.sample().filter { $0.source == .openclaw }
    work = row("ses-work")
    let unsettled = work?.activityState == .complete && work?.active == false && work?.lastOutputTokens == nil
        && work?.currentTurnOutputTokens == nil && work?.toolName == nil
    run("UPDATE session_nodes SET entry_json = ?, updated_at = ? WHERE session_key = 'agent:main:main'",
        [json(["sessionId": "ses-work", "updatedAt": ms(71), "displayName": "Generated DB title", "outputTokens": 130,
               "totalTokens": 7_000, "totalTokensFresh": true, "contextTokens": 200_000, "contextTokensSource": "runtime"]), ms(71)])
    rows = tracker.sample().filter { $0.source == .openclaw }
    work = row("ses-work")
    check(!failed && unsettled && work?.lastOutputTokens == 130 && work?.recentOutputs.map(\.tokens) == [30, 100]
          && work?.recentOutputs.last?.at == start.addingTimeInterval(71) && work?.measurementAt == start.addingTimeInterval(70)
          && work?.context?.usedTokens == 7_000 && work?.context?.windowTokens == 200_000,
          "OpenClaw SQLite: a turn ending in compressed rows was not settled by the entry's output total, or its context was stale")
}
