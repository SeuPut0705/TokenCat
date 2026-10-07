import Foundation

/// Grok Build fixture checks, run inside `runTrackerChecks`. Synthetic metadata only, temp homes.
func grokChecks(_ check: (Bool, String) -> Void) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("tokencat-grok-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let start = ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")!
    func stamp(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: start.addingTimeInterval(seconds))
    }
    func lines(_ records: [[String: Any]]) -> Data {
        records.reduce(into: Data()) { data, record in
            data.append((try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data())
            data.append(10)
        }
    }
    func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func append(_ data: Data, _ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
    func event(_ type: String, _ at: TimeInterval, _ fields: [String: Any] = [:]) -> [String: Any] {
        fields.merging(["type": type, "ts": stamp(at)]) { $1 }
    }
    func update(_ session: String, _ at: TimeInterval, _ update: [String: Any]) -> [String: Any] {
        ["method": "_x.ai/session/update", "timestamp": Int(start.timeIntervalSince1970 + at),
         "params": ["sessionId": session, "update": update,
                    "_meta": ["eventId": "\(session)-\(Int(at))", "agentTimestampMs": Int((start.timeIntervalSince1970 + at) * 1_000)]]]
    }
    func inference(_ session: String, _ at: TimeInterval, output: Int, prompt: Int, elapsed: Int) -> [String: Any] {
        ["ts": stamp(at), "src": "shell", "pid": 42, "ver": "1.0.5", "lvl": "info", "sid": session, "msg": "shell.turn.inference_done",
         "ctx": ["loop_index": 1, "model_elapsed_ms": elapsed, "ttft_ms": 500, "attempts": 1, "prompt_tokens": prompt,
                 "cached_prompt_tokens": prompt / 2, "completion_tokens": output, "reasoning_tokens": output / 2, "tokens_per_sec": 1]]
    }
    let grok = home.appendingPathComponent(".grok")
    let sessions = grok.appendingPathComponent("sessions")
    let project = sessions.appendingPathComponent("%2Ftmp%2FGrokProject")
    let main = project.appendingPathComponent("grok-main")
    let unified = grok.appendingPathComponent("logs/unified.jsonl")
    do {
        try write(lines([[
            "info": ["id": "grok-main", "cwd": "/tmp/GrokProject"], "session_summary": "PRIVATE_SUMMARY",
            "generated_title": "Fix login flow", "current_model_id": "grok-fixture", "reasoning_effort": "high",
            "context_window": 256_000, "created_at": stamp(0), "updated_at": stamp(0), "num_messages": 2,
        ]]), main.appendingPathComponent("summary.json"))
        try write(lines([
            event("turn_started", 0, ["session_id": "grok-main", "turn_number": 0, "model_id": "grok-fixture", "yolo_mode": false,
                                      "conversation_message_count": 1, "session_relationship": "primary", "schema_version": "1.0"]),
            event("loop_started", 1, ["loop_index": 0]),
            event("phase_changed", 1, ["phase": "waiting_for_model"]),
            event("phase_changed", 3, ["phase": "streaming_text"]),
            event("tool_started", 5, ["tool_name": "run_terminal_command"]),
        ]), main.appendingPathComponent("events.jsonl"))
        try write(lines([
            update("grok-main", 0, ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "PRIVATE_PROMPT"]]),
            update("grok-main", 3, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "PRIVATE_REPLY"]]),
            update("grok-main", 5, ["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "run_terminal_command",
                                    "status": "pending", "rawInput": ["command": "PRIVATE_COMMAND"]]),
        ]), main.appendingPathComponent("updates.jsonl"))
        try write(lines([
            ["ts": stamp(0), "src": "shell", "pid": 42, "lvl": "info", "msg": "session created", "ctx": ["cwd": "/tmp/GrokProject"]],
            inference("grok-main", 4, output: 40, prompt: 12_000, elapsed: 2_000),
            inference("grok-elsewhere", 4, output: 900, prompt: 1, elapsed: 1_000),
            ["ts": stamp(4), "src": "shell", "pid": 42, "lvl": "error", "sid": "grok-main", "msg": "turn.terminal_failure",
             "ctx": ["message": "PRIVATE_ERROR"]],
        ]), unified)

        var now = start.addingTimeInterval(6)
        let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
        var row = tracker.sample().first { $0.sessionID == "grok-main" }
        check(row?.source == .grok && row?.active == true && row?.activityState == .tool && row?.toolName == "run_terminal_command"
              && row?.toolCategory == .command && row?.currentTurnOutputTokens == 40 && row?.currentTurnStartedAt == start
              && row?.model == "grok-fixture" && row?.effort == "high" && row?.project == "GrokProject"
              && row?.projectPath == "/tmp/GrokProject" && row?.title == "Fix login flow" && row?.isSubagent == false
              && row?.context?.usedTokens == 12_000 && row?.context?.windowTokens == 256_000,
              "Grok: an open turn running a tool was not a tool turn with its output, model, effort, project, title and context")
        check(row?.speedMeasurement?.outputTokens == 40 && row?.speedMeasurement?.requestDurationMs == 2_000
              && row?.speedMeasurement?.ttftMs == 500 && row?.speedMeasurement?.tokensPerSecond == 20
              && row?.speedMeasurement?.model == "grok-fixture" && row?.speedMeasurement?.requestDurationIncludesRetries == false,
              "Grok: a unified-log model call's own timing was not reported as a measured request rate")

        try append(lines([event("permission_requested", 7, ["tool_name": "run_terminal_command"])]), main.appendingPathComponent("events.jsonl"))
        now = start.addingTimeInterval(3_600)
        row = tracker.sample().first { $0.sessionID == "grok-main" }
        check(row?.active == true && row?.activityState == .input && row?.toolName == "run_terminal_command",
              "Grok: an hour-old permission prompt was not live input")

        try append(lines([
            event("permission_resolved", 3_601, ["tool_name": "run_terminal_command", "decision": "allow", "wait_ms": 3_594_000]),
            event("tool_completed", 3_602, ["tool_name": "run_terminal_command", "duration_ms": 900, "outcome": "success", "tool_call_id": "c1"]),
            event("phase_changed", 3_603, ["phase": "waiting_for_model"]),
            event("turn_ended", 3_605, ["outcome": "completed"]),
        ]), main.appendingPathComponent("events.jsonl"))
        try append(lines([inference("grok-main", 3_604, output: 60, prompt: 13_000, elapsed: 3_000)]), unified)
        try append(lines([update("grok-main", 3_605, ["sessionUpdate": "turn_completed", "prompt_id": "p1", "stop_reason": "end_turn",
                                                      "agent_result": "PRIVATE_RESULT", "elapsed_ms": 3_605_000,
                                                      "usage": ["inputTokens": 25_000, "outputTokens": 999, "modelCalls": 2]])]),
                   main.appendingPathComponent("updates.jsonl"))
        now = start.addingTimeInterval(3_610)
        row = tracker.sample().first { $0.sessionID == "grok-main" }
        check(row?.active == false && row?.activityState == .complete && row?.lastOutputTokens == 100 && row?.toolName == nil
              && row?.currentTurnOutputTokens == nil && row?.recentOutputs.map(\.tokens) == [60] && row?.lastTurnDurationSeconds == 3_605
              && row?.context?.usedTokens == 13_000 && row?.speedMeasurement?.tokensPerSecond == 20,
              "Grok: a completed turn did not total its unified-log calls once (turn_completed usage counted again), or lost its duration")

        // Grok trims unified.jsonl to its newer half in place: lines read again are not new calls.
        let trimmed = lines([inference("grok-main", 3_604, output: 60, prompt: 13_000, elapsed: 3_000)])
        let handle = try FileHandle(forWritingTo: unified)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: trimmed)
        try handle.close()
        row = tracker.sample().first { $0.sessionID == "grok-main" }
        check(row?.lastOutputTokens == 100 && row?.recentOutputs.map(\.tokens) == [60],
              "Grok: lines kept by a unified-log trim were counted again")

        // A session the unified log does not cover: turn_completed usage counts; a /rename title shows.
        let renamed = project.appendingPathComponent("grok-renamed")
        try write(lines([["info": ["id": "grok-renamed", "cwd": "/tmp/GrokProject"], "generated_title": "Renamed by person",
                          "title_is_manual": true, "session_summary": "PRIVATE", "current_model_id": "grok-fixture"]]),
                  renamed.appendingPathComponent("summary.json"))
        try write(lines([event("turn_started", 3_620, ["model_id": "grok-fixture", "session_relationship": "primary"]),
                         event("turn_ended", 3_630, ["outcome": "completed"])]), renamed.appendingPathComponent("events.jsonl"))
        try write(lines([update("grok-renamed", 3_629, ["sessionUpdate": "turn_completed", "prompt_id": "p", "stop_reason": "end_turn",
                                                        "usage": ["outputTokens": 77]])]), renamed.appendingPathComponent("updates.jsonl"))
        // A slug-and-hash cwd folder names its path in `.cwd`. A failed title request leaves the first prompt's opening
        // words as the title, which never shows. A /fork names its parent but stays top-level.
        let long = sessions.appendingPathComponent("longproject-0123456789abcdef")
        try write(Data("/tmp/LongProject\n".utf8), long.appendingPathComponent(".cwd"))
        let untitled = long.appendingPathComponent("grok-untitled")
        try write(lines([["session_summary": "PRIVATE opening words of the prompt", "generated_title": "PRIVATE opening words of the prompt",
                          "session_kind": "fork", "parent_session_id": "grok-main", "current_model_id": "grok-fixture"]]),
                  untitled.appendingPathComponent("summary.json"))
        try write(lines([event("turn_started", 3_620, ["model_id": "grok-fixture"]), event("turn_ended", 3_625, ["outcome": "cancelled"])]),
                  untitled.appendingPathComponent("events.jsonl"))
        try write(lines([update("grok-untitled", 3_619, ["sessionUpdate": "hook_execution", "event_name": "session_start"]),
                         update("grok-untitled", 3_620, ["sessionUpdate": "user_message_chunk", "_meta": ["promptIndex": 0],
                                                         "content": ["type": "text", "text": "PRIVATE opening\nwords of the  prompt and more"]])]),
                  untitled.appendingPathComponent("updates.jsonl"))
        // A subagent running in a worktree: the parent's subagents/<id>/meta.json names its parent and type.
        let child = sessions.appendingPathComponent("%2Ftmp%2FGrokWorktree/grok-child")
        try write(lines([["info": ["id": "grok-child", "cwd": "/tmp/GrokWorktree"], "session_kind": "subagent",
                          "agent_name": "general-purpose", "current_model_id": "grok-sub", "session_summary": "PRIVATE"]]),
                  child.appendingPathComponent("summary.json"))
        try write(lines([event("turn_started", 3_620, ["model_id": "grok-sub", "session_relationship": "primary"]),
                         event("tool_started", 3_622, ["tool_name": "read_file"])]), child.appendingPathComponent("events.jsonl"))
        try write(lines([update("grok-child", 3_620, ["sessionUpdate": "user_message_chunk", "content": ["text": "PRIVATE_TASK"]])]),
                  child.appendingPathComponent("updates.jsonl"))
        try write(lines([["subagent_id": "grok-child", "parent_session_id": "grok-main", "child_session_id": "grok-child",
                          "subagent_type": "explore", "description": "PRIVATE_DESCRIPTION", "prompt": "PRIVATE_PROMPT"]]),
                  main.appendingPathComponent("subagents/grok-child/meta.json"))
        try append(lines([inference("grok-child", 3_621, output: 7, prompt: 900, elapsed: 700)]), unified)
        now = start.addingTimeInterval(3_632)
        let rows = tracker.sample().filter { $0.source == .grok }
        let renamedRow = rows.first { $0.sessionID == "grok-renamed" }
        check(renamedRow?.activityState == .complete && renamedRow?.lastOutputTokens == 77 && renamedRow?.title == "Renamed by person"
              && renamedRow?.speedMeasurement == nil,
              "Grok: a turn outside the unified log did not count its turn_completed usage, or a renamed title was not shown")
        let untitledRow = rows.first { $0.sessionID == "grok-untitled" }
        check(untitledRow?.title == nil && untitledRow?.project == "LongProject" && untitledRow?.projectPath == "/tmp/LongProject"
              && untitledRow?.activityState == .interrupted && untitledRow?.isSubagent == false && untitledRow?.parentSessionID == nil,
              "Grok: a fallback title copied from the first prompt showed, a .cwd folder lost its path, or a fork became a subagent")
        let childRow = rows.first { $0.sessionID == "grok-child" }
        check(childRow?.isSubagent == true && childRow?.parentSessionID == "grok-main" && childRow?.agentID == "grok-child"
              && childRow?.agentRole == "explore" && childRow?.activityState == .tool && childRow?.toolName == "read_file"
              && childRow?.toolCategory == .file && childRow?.currentTurnOutputTokens == 7 && childRow?.model == "grok-sub"
              && childRow?.project == "GrokWorktree" && childRow?.title == nil,
              "Grok: a worktree subagent was not grouped under its parent with its type, tool and output")
        let encoded = String(decoding: (try? JSONEncoder().encode(rows)) ?? Data(), as: UTF8.self)
        check(rows.count == 4 && !encoded.contains("PRIVATE"), "Grok: message text leaked into a reading, or a session row is missing")
        check(tracker.isLog(main.appendingPathComponent("updates.jsonl").path) && !tracker.isLog(main.appendingPathComponent("events.jsonl").path)
              && !tracker.isLog(main.appendingPathComponent("subagents/grok-child/meta.json").path) && !tracker.isLog(unified.path),
              "Grok: file events of the session update log were ignored, or other Grok files woke sampling")
    } catch {
        check(false, "Grok fixtures could not be written: \(error)")
    }
}
