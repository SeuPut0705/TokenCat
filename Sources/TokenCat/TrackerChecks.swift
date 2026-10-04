import Foundation

/// Synthetic metadata-only regressions. No network calls, accounts, or actual transcript text.
func runTrackerChecks() -> [String] {
    var failures: [String] = []
    var checks = 0
    func check(_ valid: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !valid() { failures.append(description) }
    }
    func line(_ value: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        data.append(10)
        return data
    }
    func feed(_ parser: TokenLogParser, _ value: [String: Any]) {
        parser.consume(line(value))
    }
    func codex(_ type: String, _ timestamp: String, _ extras: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["type": type]
        extras.forEach { payload[$0.key] = $0.value }
        return ["type": "event_msg", "timestamp": timestamp, "payload": payload]
    }
    func usage(_ total: Int, _ last: Int, _ timestamp: String) -> [String: Any] {
        codex("token_count", timestamp, ["info": [
            "total_token_usage": ["output_tokens": total, "input_tokens": 90_000,
                                  "cached_input_tokens": 80_000, "reasoning_output_tokens": total / 2],
            "last_token_usage": ["output_tokens": last, "input_tokens": 90_000]
        ]])
    }
    func assistant(_ id: String, _ count: Int, _ timestamp: String, _ uuid: String) -> [String: Any] {
        ["type": "assistant", "timestamp": timestamp, "uuid": uuid,
         "message": ["id": id, "model": "fixture-model", "usage": ["output_tokens": count,
             "input_tokens": 60_000, "cache_creation_input_tokens": 40_000, "cache_read_input_tokens": 50_000]]]
    }

    let parser = TokenLogParser(source: .codex)
    feed(parser, usage(1_000, 30, "2026-10-04T01:00:00Z"))
    feed(parser, codex("task_started", "2026-10-04T01:00:01Z", ["turn_id": "turn-a"]))
    feed(parser, usage(1_100, 100, "2026-10-04T01:00:02.500Z"))
    feed(parser, usage(1_100, 100, "2026-10-04T01:00:02.600Z"))
    feed(parser, usage(1_150, 50, "2026-10-04T01:00:03Z"))
    feed(parser, codex("task_complete", "2026-10-04T01:00:04Z", ["turn_id": "turn-a", "duration_ms": 3_000]))
    check(parser.completion?.output == 150, "Codex: duplicate cumulative usage or cache/reasoning was counted twice")
    check(parser.completion?.durationSeconds == 3 && parser.lastTurnDuration == 3,
          "Codex: the client-reported turn duration must be kept apart from its output")
    feed(parser, codex("task_started", "2026-10-04T01:00:05Z", ["turn_id": "turn-a"]))
    check(!parser.isActive(at: ISO8601DateFormatter().date(from: "2026-10-04T01:00:05Z")!), "Codex: replayed completed turn reopened")

    let compacted = TokenLogParser(source: .codex)
    feed(compacted, codex("task_started", "2026-10-04T02:00:00Z", ["turn_id": "compact"]))
    feed(compacted, usage(100, 100, "2026-10-04T02:00:01Z"))
    feed(compacted, usage(20, 20, "2026-10-04T02:00:02Z"))
    feed(compacted, usage(60, 40, "2026-10-04T02:00:03Z"))
    feed(compacted, codex("task_complete", "2026-10-04T02:00:04Z", ["turn_id": "compact", "duration_ms": 4_000]))
    check(compacted.completion?.output == 160, "Codex: cumulative reset during compaction")
    let tail = TokenLogParser(source: .codex)
    feed(tail, usage(900, 50, "2026-10-04T02:00:01Z"))
    feed(tail, codex("task_complete", "2026-10-04T02:00:02Z", ["turn_id": "missing", "duration_ms": 2_000]))
    check(tail.completion == nil, "Codex: missing turn start invented a speed")

    let forked = TokenLogParser(source: .codex)
    feed(forked, ["type": "session_meta", "payload": ["id": "child-session", "cwd": "/tmp/ChildProject",
        "timestamp": "2026-10-04T02:00:10Z", "source": ["subagent": ["parent_thread_id": "parent"]],
        "agent_path": "/root/child"]])
    feed(forked, codex("task_started", "2026-10-04T02:00:11Z",
        ["turn_id": "parent-turn", "started_at": "2026-10-04T02:00:00Z"]))
    feed(forked, usage(100, 100, "2026-10-04T02:00:12Z"))
    feed(forked, codex("task_complete", "2026-10-04T02:00:13Z", ["turn_id": "parent-turn", "duration_ms": 13_000]))
    check(forked.completion == nil && forked.lastActivity == nil && forked.latestOutput == nil,
          "Forked Codex session inherited parent turn usage or activity")
    feed(forked, ["type": "turn_context", "payload": ["model": "child-model", "turn_id": "child-turn"]])
    feed(forked, codex("task_started", "2026-10-04T02:00:14Z", ["turn_id": "child-turn"]))
    feed(forked, usage(120, 20, "2026-10-04T02:00:14.500Z"))
    feed(forked, codex("task_complete", "2026-10-04T02:00:15Z", ["turn_id": "child-turn", "duration_ms": 1_000]))
    check(forked.isSubagent && forked.completion?.output == 20 && forked.lastTurnDuration == 1
          && forked.model == "child-model" && forked.completion?.model == "child-model",
          "Forked Codex session failed to measure its own first turn independently")

    let claude = TokenLogParser(source: .claude)
    feed(claude, ["type": "user", "uuid": "human", "timestamp": "2026-10-04T03:00:00Z",
                  "message": ["content": [["type": "text"]]]])
    feed(claude, assistant("msg-a", 100, "2026-10-04T03:00:01.500Z", "a1"))
    feed(claude, assistant("msg-a", 150, "2026-10-04T03:00:02Z", "a2"))
    feed(claude, ["type": "user", "uuid": "tool", "timestamp": "2026-10-04T03:00:03Z",
                  "message": ["content": [["type": "tool_result"]]]])
    feed(claude, assistant("msg-b", 50, "2026-10-04T03:00:04Z", "b"))
    feed(claude, assistant("msg-b", 50, "2026-10-04T03:00:04.500Z", "b2"))
    feed(claude, ["type": "system", "subtype": "turn_duration", "parentUuid": "b2",
                  "timestamp": "2026-10-04T03:00:05Z", "durationMs": 5_000])
    check(claude.completion?.output == 200, "Claude: message ID maximum usage or tool-result boundary")
    check(claude.completion?.durationSeconds == 5 && claude.context?.usedTokens == 150_000
          && claude.context?.windowTokens == nil,
          "Claude: durationMs or the absolute input-side context (input + cache) was not kept")
    feed(claude, ["type": "user", "uuid": "human2", "timestamp": "2026-10-04T03:01:00Z",
                  "message": ["content": [["type": "text"]]]])
    feed(claude, assistant("msg-a", 150, "2026-10-04T03:01:01Z", "old"))
    feed(claude, assistant("msg-c", 30, "2026-10-04T03:01:02Z", "c"))
    feed(claude, ["type": "system", "subtype": "turn_duration", "parentUuid": "c",
                  "timestamp": "2026-10-04T03:01:03Z", "durationMs": 3_000])
    check(claude.completion?.output == 30, "Claude: prior-turn message replay leaked into a new turn")
    let unknown = TokenLogParser(source: .claude)
    feed(unknown, ["type": "user", "uuid": "human", "timestamp": "2026-10-04T03:00:00Z",
                   "message": ["content": [["type": "text"]]]])
    feed(unknown, assistant("msg", 100, "2026-10-04T03:00:02Z", "out"))
    feed(unknown, ["type": "system", "subtype": "turn_duration", "timestamp": "2026-10-04T03:00:03Z"])
    check(unknown.completion?.output == 100 && unknown.completion?.durationSeconds == nil && unknown.lastTurnDuration == nil,
          "Claude: a missing durationMs must stay unknown rather than come from log times")
    check(!unknown.isActive(at: ISO8601DateFormatter().date(from: "2026-10-04T04:00:03Z")!), "Old unfinished turn stayed active")
    let claudeTail = TokenLogParser(source: .claude)
    feed(claudeTail, assistant("tail", 100, "2026-10-04T03:00:02Z", "out"))
    feed(claudeTail, ["type": "system", "subtype": "turn_duration", "timestamp": "2026-10-04T03:00:03Z", "durationMs": 3_000])
    check(claudeTail.completion == nil, "Claude: unknown tail start invented a complete turn")

    let liveCodex = TokenLogParser(source: .codex)
    let liveStart = ISO8601DateFormatter().date(from: "2026-10-04T03:00:00Z")!
    feed(liveCodex, codex("task_started", "2026-10-04T03:00:00Z", ["turn_id": "live-codex"]))
    check(liveCodex.currentTurnStartedAt == liveStart && liveCodex.currentTurnOutputTokens == 0
          && liveCodex.activityState(at: liveStart) == .working && liveCodex.lastOutputDelta == nil,
          "Codex live: a newly observed turn must start at zero with no previous output chunk")
    feed(liveCodex, usage(100, 100, "2026-10-04T03:00:01Z"))
    feed(liveCodex, usage(100, 100, "2026-10-04T03:00:02Z"))
    check(liveCodex.currentTurnOutputTokens == 100 && liveCodex.lastOutputDelta == 100
          && liveCodex.lastOutputAt == liveStart.addingTimeInterval(1),
          "Codex live: duplicate cumulative usage must not refresh or multiply output delta")
    for id in ["tool-a", "tool-b"] {
        feed(liveCodex, ["type": "response_item", "timestamp": "2026-10-04T03:00:03Z",
                         "payload": ["type": "function_call", "call_id": id]])
    }
    feed(liveCodex, ["type": "response_item", "timestamp": "2026-10-04T03:00:04Z",
                     "payload": ["type": "function_call_output", "call_id": "tool-a"]])
    check(liveCodex.activityState(at: liveStart.addingTimeInterval(4)) == .tool,
          "Codex live: one completed tool must not clear another outstanding call")
    feed(liveCodex, ["type": "response_item", "timestamp": "2026-10-04T03:00:05Z",
                     "payload": ["type": "function_call_output", "call_id": "tool-b"]])
    check(liveCodex.activityState(at: liveStart.addingTimeInterval(5)) == .working,
          "Codex live: matching final tool result should return to working state")
    check(liveCodex.activityState(at: liveStart.addingTimeInterval(300)) == .working
          && liveCodex.isActive(at: liveStart.addingTimeInterval(300)),
          "Codex live: a long model wait (no tool pending) must stay running within ten minutes")
    check(liveCodex.activityState(at: liveStart.addingTimeInterval(700)) == .stale
          && liveCodex.currentTurnStartedAt == liveStart && liveCodex.currentTurnOutputTokens == 100,
          "Codex live: stale logs must keep elapsed time without claiming completion")
    check(liveCodex.activityState(at: liveStart.addingTimeInterval(2_000)) == .unfinished
          && !liveCodex.isActive(at: liveStart.addingTimeInterval(2_000)),
          "Codex live: an open turn silent for over 30 minutes must not stay in the waiting state")
    feed(liveCodex, codex("task_complete", "2026-10-04T03:00:06Z", ["turn_id": "live-codex", "duration_ms": 6_000]))
    check(liveCodex.currentTurnStartedAt == nil && liveCodex.currentTurnOutputTokens == nil
          && liveCodex.activityState(at: liveStart.addingTimeInterval(6)) == .complete,
          "Codex live: completed turns must clear current-turn counters")
    feed(liveCodex, codex("task_started", "2026-10-04T03:00:07Z", ["turn_id": "next-codex"]))
    check(liveCodex.currentTurnOutputTokens == 0 && liveCodex.lastOutputAt == nil && liveCodex.lastOutputDelta == nil,
          "Codex live: a new turn leaked the previous turn's output delta")
    feed(liveCodex, codex("turn_aborted", "2026-10-04T03:00:08Z", ["turn_id": "next-codex"]))
    check(liveCodex.activityState(at: liveStart.addingTimeInterval(8)) == .interrupted
          && liveCodex.currentTurnStartedAt == nil && liveCodex.currentTurnOutputTokens == nil,
          "Codex live: interrupted turn state or current counters were not cleared")
    let unknownLiveCount = TokenLogParser(source: .codex)
    feed(unknownLiveCount, codex("task_started", "2026-10-04T03:00:00Z", ["turn_id": "unknown-count"]))
    feed(unknownLiveCount, codex("token_count", "2026-10-04T03:00:01Z",
        ["info": ["total_token_usage": ["output_tokens": "unavailable"]]]))
    check(unknownLiveCount.currentTurnOutputTokens == nil && unknownLiveCount.lastOutputDelta == nil,
          "Codex live: an unrecognized output counter must remain unknown, not fall back to zero")

    func usageRecord(_ response: String, turn: String, output: Int, turnTotal: Int, _ timestamp: String) -> [String: Any] {
        ["type": "token_usage_record", "timestamp": timestamp, "payload": [
            "turn_id": turn, "response_id": response,
            "usage": ["output_tokens": output, "input_tokens": 90_000],
            "turn_token_usage": ["output_tokens": turnTotal, "input_tokens": 900_000],
            "thread_token_usage": ["output_tokens": turnTotal + 10_000]]]
    }
    let recorded = TokenLogParser(source: .codex)
    feed(recorded, usage(10_000, 300, "2026-10-04T05:00:00Z"))
    feed(recorded, codex("task_started", "2026-10-04T05:00:01Z", ["turn_id": "usage-turn"]))
    feed(recorded, usageRecord("resp-1", turn: "usage-turn", output: 120, turnTotal: 120, "2026-10-04T05:00:02Z"))
    feed(recorded, ["type": "response_item", "timestamp": "2026-10-04T05:00:02Z",
                    "payload": ["type": "function_call", "call_id": "long-tool"]])
    let usageStart = ISO8601DateFormatter().date(from: "2026-10-04T05:00:02Z")!
    check(recorded.currentTurnOutputTokens == 120 && recorded.lastOutputDelta == 120
          && recorded.lastOutputAt == usageStart && recorded.recentOutputs.last?.tokens == 120,
          "Codex usage record: a response must count before its tool finishes and token_count arrives")
    feed(recorded, ["type": "response_item", "timestamp": "2026-10-04T05:03:00Z",
                    "payload": ["type": "function_call_output", "call_id": "long-tool"]])
    feed(recorded, usage(10_120, 120, "2026-10-04T05:03:00Z"))
    feed(recorded, usageRecord("resp-1", turn: "usage-turn", output: 120, turnTotal: 120, "2026-10-04T05:03:01Z"))
    check(recorded.currentTurnOutputTokens == 120 && recorded.lastOutputAt == usageStart
          && recorded.recentOutputs.filter { $0.at >= usageStart }.count == 1,
          "Codex usage record: the delayed token_count or a repeated response_id was counted again")
    feed(recorded, usageRecord("resp-compact", turn: "usage-turn", output: 4_000, turnTotal: 4_120, "2026-10-04T05:03:02Z"))
    feed(recorded, usage(10_120, 0, "2026-10-04T05:03:02Z"))
    feed(recorded, usageRecord("resp-other", turn: "foreign-turn", output: 999, turnTotal: 999, "2026-10-04T05:03:03Z"))
    check(recorded.currentTurnOutputTokens == 4_120 && recorded.lastOutputDelta == 4_000,
          "Codex usage record: compaction output was dropped, or another turn's record leaked into the open turn")
    feed(recorded, codex("task_complete", "2026-10-04T05:03:05Z", ["turn_id": "usage-turn", "duration_ms": 184_000]))
    check(recorded.completion?.output == 4_120 && recorded.currentTurnOutputTokens == nil,
          "Codex usage record: completed turn must report the recorded turn total and clear live counters")

    let inheritedUsage = TokenLogParser(source: .codex)
    feed(inheritedUsage, ["type": "session_meta", "payload": ["id": "fork", "timestamp": "2026-10-04T05:10:00Z",
        "source": ["subagent": ["parent_thread_id": "parent"]]]])
    feed(inheritedUsage, codex("task_started", "2026-10-04T05:10:01Z",
        ["turn_id": "parent-turn", "started_at": "2026-10-04T05:00:00Z"]))
    feed(inheritedUsage, usageRecord("parent-resp", turn: "parent-turn", output: 500, turnTotal: 500, "2026-10-04T05:10:01Z"))
    check(inheritedUsage.lastOutputDelta == nil && inheritedUsage.recentOutputs.isEmpty && inheritedUsage.lastActivity == nil,
          "Codex usage record: an inherited parent response was counted in a forked log")

    // Liveness horizons: Codex tools yield quickly; any record keeps a turn alive.
    let toolWait = TokenLogParser(source: .codex)
    feed(toolWait, codex("task_started", "2026-10-04T06:00:00Z", ["turn_id": "tool-wait"]))
    feed(toolWait, ["type": "response_item", "timestamp": "2026-10-04T06:00:01Z",
                    "payload": ["type": "function_call", "call_id": "stuck"]])
    let toolWaitStart = ISO8601DateFormatter().date(from: "2026-10-04T06:00:00Z")!
    check(toolWait.activityState(at: toolWaitStart.addingTimeInterval(150)) == .stale,
          "Codex liveness: a tool silent past its 120 s horizon must become log-waiting")
    feed(toolWait, ["type": "world_state", "timestamp": "2026-10-04T06:08:00Z", "payload": ["full": true]])
    check(toolWait.isActive(at: toolWaitStart.addingTimeInterval(530)) && toolWait.lastActivity == toolWaitStart.addingTimeInterval(1),
          "Codex liveness: any newer record must keep the turn alive without becoming content activity")
    // Codex plan-mode questions block on the person; the async variant returns at once.
    for (name, waits) in [("request_user_input", true), ("request_user_input_async", false)] {
        let question = TokenLogParser(source: .codex)
        feed(question, codex("task_started", "2026-10-04T06:00:00Z", ["turn_id": "question"]))
        feed(question, ["type": "response_item", "timestamp": "2026-10-04T06:00:01Z",
                        "payload": ["type": "function_call", "call_id": "q", "name": name, "arguments": "PRIVATE_INPUT"]])
        let state = question.activityState(at: toolWaitStart.addingTimeInterval(600))
        check(waits ? state == .input && question.isActive(at: toolWaitStart.addingTimeInterval(600)) : state == .stale,
              "Codex input state: \(name) must \(waits ? "wait for the person" : "follow the 120 s tool horizon")")
    }

    func claudeUser(_ uuid: String, _ timestamp: String, content: Any, extra: [String: Any] = [:]) -> [String: Any] {
        var record: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": ["content": content]]
        extra.forEach { record[$0.key] = $0.value }
        return record
    }
    func claudeReply(_ id: String, _ count: Int, _ timestamp: String, _ uuid: String,
                     blocks: [[String: Any]], stop: String? = nil, model: String = "fixture-model") -> [String: Any] {
        var message: [String: Any] = ["id": id, "model": model, "usage": ["output_tokens": count], "content": blocks]
        if let stop { message["stop_reason"] = stop }
        return ["type": "assistant", "timestamp": timestamp, "uuid": uuid, "message": message]
    }
    let closeStart = ISO8601DateFormatter().date(from: "2026-10-04T07:00:00Z")!
    let workflowAgent = TokenLogParser(source: .claude, isSubagent: true)
    feed(workflowAgent, claudeUser("w-in", "2026-10-04T07:00:00Z", content: "task", extra: ["isSidechain": true]))
    feed(workflowAgent, claudeReply("w-msg", 80, "2026-10-04T07:00:02Z", "w-out", blocks: [["type": "tool_use", "id": "w-tool"]],
                                    stop: "tool_use"))
    feed(workflowAgent, claudeUser("w-end", "2026-10-04T07:00:03Z", content: [["type": "tool_result", "tool_use_id": "w-tool"]],
                                   extra: ["isSidechain": true, "toolEndsTurn": true]))
    check(workflowAgent.activityState(at: closeStart.addingTimeInterval(4)) == .complete
          && !workflowAgent.isActive(at: closeStart.addingTimeInterval(4)) && workflowAgent.currentTurnStartedAt == nil,
          "Claude close: a workflow agent's turn-ending tool result must complete it")

    let replied = TokenLogParser(source: .claude)
    feed(replied, claudeUser("r-in", "2026-10-04T07:00:00Z", content: "hello", extra: ["origin": ["kind": "human"]]))
    feed(replied, claudeReply("r-msg", 40, "2026-10-04T07:00:02Z", "r-out", blocks: [["type": "text"]], stop: "end_turn"))
    check(replied.activityState(at: closeStart.addingTimeInterval(3)) == .complete && replied.currentTurnOutputTokens == nil,
          "Claude close: a final reply without tool use must close the turn even without a stop marker")
    feed(replied, claudeReply("r-more", 25, "2026-10-04T07:00:05Z", "r-more", blocks: [["type": "text"]]))
    check(replied.isActive(at: closeStart.addingTimeInterval(6)) && replied.currentTurnOutputTokens == 65
          && replied.currentTurnStartedAt == closeStart,
          "Claude close: output after a final reply (blocking Stop hook) must reopen the same turn")
    feed(replied, ["type": "system", "subtype": "stop_hook_summary", "parentUuid": "unseen-attachment",
                   "timestamp": "2026-10-04T07:00:06Z"])
    check(replied.activityState(at: closeStart.addingTimeInterval(7)) == .complete && !replied.isActive(at: closeStart.addingTimeInterval(7)),
          "Claude close: a stop marker whose parent is an attachment must still end the turn")
    feed(replied, claudeUser("r-cmd", "2026-10-04T07:01:00Z", content: "<command-name>/compact</command-name>"))
    check(replied.currentTurnStartedAt == nil && replied.activityState(at: closeStart.addingTimeInterval(61)) == .complete,
          "Claude close: a local slash-command echo must not open a turn")
    feed(replied, claudeUser("r-note", "2026-10-04T07:02:00Z", content: "done",
                             extra: ["origin": ["kind": "task-notification"]]))
    check(replied.currentTurnStartedAt == closeStart.addingTimeInterval(120),
          "Claude close: a task notification prompt must start a turn")
    feed(replied, claudeReply("r-err", 0, "2026-10-04T07:02:01Z", "r-err", blocks: [["type": "text"]],
                              stop: "stop_sequence", model: "<synthetic>"))
    check(replied.activityState(at: closeStart.addingTimeInterval(122)) == .interrupted && replied.model == "fixture-model",
          "Claude close: an API error reply must interrupt the turn without replacing the model")
    feed(replied, claudeUser("r-again", "2026-10-04T07:03:00Z", content: "again", extra: ["origin": ["kind": "human"]]))
    feed(replied, claudeUser("r-stop", "2026-10-04T07:03:01Z", content: [["type": "text", "text": "[Request interrupted by user]"]]))
    check(replied.activityState(at: closeStart.addingTimeInterval(182)) == .interrupted && replied.currentTurnStartedAt == nil,
          "Claude close: an interruption notice must end the turn rather than start a new one")

    let replayed = TokenLogParser(source: .claude)
    feed(replayed, claudeUser("p-in", "2026-10-04T08:00:00Z", content: "first", extra: ["origin": ["kind": "human"]]))
    feed(replayed, claudeReply("p-msg", 30, "2026-10-04T08:00:01Z", "p-a", blocks: [["type": "thinking"]], stop: "tool_use"))
    feed(replayed, claudeReply("p-msg", 30, "2026-10-04T08:00:04Z", "p-b", blocks: [["type": "tool_use", "id": "p-tool"]], stop: "tool_use"))
    let replayStart = ISO8601DateFormatter().date(from: "2026-10-04T08:00:00Z")!
    check(replayed.currentTurnOutputTokens == 30 && replayed.lastOutputAt == replayStart.addingTimeInterval(4)
          && replayed.recentOutputs.count == 1 && replayed.recentOutputs.last?.at == replayStart.addingTimeInterval(4),
          "Claude freshness: later blocks of one message must move its record time without counting again")
    feed(replayed, claudeUser("old-in", "2026-10-04T07:00:00Z", content: "restored", extra: ["origin": ["kind": "human"]]))
    feed(replayed, claudeUser("p-in", "2026-10-04T08:00:00Z", content: "first", extra: ["origin": ["kind": "human"]]))
    check(replayed.currentTurnStartedAt == replayStart && replayed.currentTurnOutputTokens == 30
          && replayed.activityState(at: replayStart.addingTimeInterval(5)) == .tool,
          "Claude replay: re-appended history must not rewind the open turn")
    var oversized = Data("{\"parentUuid\":\"p-b\",\"isSidechain\":false,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"p-tool\",\"type\":\"tool_result\",\"content\":\"".utf8)
    oversized.append(Data(repeating: 120, count: 20_000))
    replayed.consumeOversizedPrefix(oversized.prefix(16_384))
    check(replayed.activityState(at: replayStart.addingTimeInterval(6)) == .working,
          "Oversized tool result: the call named in its prefix must stop counting as a running tool")

    let liveClaude = TokenLogParser(source: .claude)
    feed(liveClaude, ["type": "user", "uuid": "live-human", "timestamp": "2026-10-04T03:00:00Z",
                      "message": ["content": [["type": "text"]]]])
    var partialUsage = assistant("partial-msg", 3, "2026-10-04T03:00:01Z", "partial")
    var partialMessage = partialUsage["message"] as! [String: Any]
    partialMessage["content"] = [["type": "thinking"]]
    partialUsage["message"] = partialMessage
    feed(liveClaude, partialUsage)
    var finalUsage = assistant("partial-msg", 264, "2026-10-04T03:00:02Z", "final")
    var finalMessage = finalUsage["message"] as! [String: Any]
    finalMessage["content"] = [["type": "tool_use", "id": "claude-tool"]]
    finalUsage["message"] = finalMessage
    feed(liveClaude, finalUsage)
    feed(liveClaude, finalUsage)
    check(liveClaude.currentTurnOutputTokens == 264 && liveClaude.lastOutputDelta == 261
          && liveClaude.activityState(at: liveStart.addingTimeInterval(2)) == .tool,
          "Claude live: progressive 3→264 usage must add 261 once, not keep the first fragment or double-count final usage")
    feed(liveClaude, ["type": "user", "uuid": "live-result", "timestamp": "2026-10-04T03:00:03Z",
                      "message": ["content": [["type": "tool_result", "tool_use_id": "claude-tool"]]]])
    check(liveClaude.activityState(at: liveStart.addingTimeInterval(3)) == .working
          && liveClaude.currentTurnOutputTokens == 264 && liveClaude.currentTurnStartedAt == liveStart,
          "Claude live: a tool result must preserve the human turn's output and elapsed-time origin")
    feed(liveClaude, ["type": "system", "subtype": "turn_duration", "parentUuid": "final",
                      "timestamp": "2026-10-04T03:00:04Z", "durationMs": 4_000])
    check(liveClaude.activityState(at: liveStart.addingTimeInterval(4)) == .complete
          && liveClaude.currentTurnOutputTokens == nil && liveClaude.currentTurnStartedAt == nil,
          "Claude live: an actual completion must clear current-turn metadata")
    feed(liveClaude, ["type": "user", "uuid": "next-human", "timestamp": "2026-10-04T03:00:05Z",
                      "message": ["content": [["type": "text"]]]])
    check(liveClaude.lastOutputDelta == nil && liveClaude.lastOutputAt == nil && liveClaude.currentTurnOutputTokens == 0,
          "Claude live: new human input must reset the previous output chunk")
    let confirmedBeforeInterruption = liveClaude.completion
    var interruptedCandidate = assistant("interrupted-candidate", 1_000, "2026-10-04T03:00:06Z", "candidate")
    interruptedCandidate["parentUuid"] = "next-human"
    interruptedCandidate["requestId"] = "interrupted-request"
    var candidateMessage = interruptedCandidate["message"] as! [String: Any]
    candidateMessage["stop_reason"] = "tool_use"
    candidateMessage["content"] = [["type": "tool_use", "id": "interrupted-tool"]]
    interruptedCandidate["message"] = candidateMessage
    feed(liveClaude, interruptedCandidate)
    feed(liveClaude, ["type": "system", "subtype": "interrupted", "timestamp": "2026-10-04T03:00:07Z"])
    feed(liveClaude, ["type": "user", "uuid": "after-interruption", "timestamp": "2026-10-04T03:00:08Z",
                      "message": ["content": [["type": "text"]]]])
    let completionAfterNewInput = liveClaude.completion
    feed(liveClaude, assistant("recovered-response", 10, "2026-10-04T03:00:10Z", "recovered"))
    feed(liveClaude, ["type": "system", "subtype": "turn_duration", "parentUuid": "recovered",
                      "timestamp": "2026-10-04T03:00:10Z", "durationMs": 2_000])
    check(completionAfterNewInput?.output == confirmedBeforeInterruption?.output
          && completionAfterNewInput?.finishedAt == confirmedBeforeInterruption?.finishedAt
          && liveClaude.completion?.output == 10 && liveClaude.lastTurnDuration == 2,
          "Claude interruption promoted an unconfirmed response candidate or damaged the next valid turn")

    let estimated = TokenLogParser(source: .claude)
    feed(estimated, ["type": "user", "uuid": "input", "timestamp": "2026-10-04T03:00:00Z",
                     "message": ["content": [["type": "tool_result"]]]])
    feed(estimated, ["type": "attachment", "uuid": "attached", "parentUuid": "input",
                     "timestamp": "2026-10-04T03:00:00.010Z"])
    var thought = assistant("estimated", 200, "2026-10-04T03:00:01Z", "thought")
    thought["parentUuid"] = "attached"
    thought["requestId"] = "request"
    var thoughtMessage = thought["message"] as! [String: Any]
    thoughtMessage["stop_reason"] = "tool_use"
    thoughtMessage["content"] = [["type": "thinking"]]
    thought["message"] = thoughtMessage
    feed(estimated, thought)
    check(estimated.completion == nil, "Claude estimate: full usage on an early thinking fragment exposed a speed")
    var terminal = assistant("estimated", 200, "2026-10-04T03:00:04Z", "terminal")
    terminal["parentUuid"] = "thought"
    terminal["requestId"] = "request"
    var terminalMessage = terminal["message"] as! [String: Any]
    terminalMessage["stop_reason"] = "tool_use"
    terminalMessage["content"] = [["type": "tool_use"]]
    terminal["message"] = terminalMessage
    feed(estimated, terminal)
    check(estimated.completion == nil, "Claude estimate: an unconfirmed streaming fragment exposed a speed")
    feed(estimated, ["type": "user", "uuid": "tool-next", "parentUuid": "terminal",
                     "timestamp": "2026-10-04T03:00:10Z", "message": ["content": [["type": "tool_result"]]]])
    check(estimated.completion == nil && estimated.latestOutput == 200,
          "Claude log timestamps must not invent a generation speed while confirmed tokens remain available")
    feed(estimated, ["type": "system", "subtype": "stop_hook_summary", "parentUuid": "terminal",
                     "timestamp": "2026-10-04T03:00:11Z"])
    check(estimated.completion == nil && estimated.activityState(at: liveStart.addingTimeInterval(11)) == .complete,
          "Claude stop without measured duration must close the turn without inventing a speed")
    let unanchored = TokenLogParser(source: .claude)
    feed(unanchored, terminal)
    feed(unanchored, ["type": "system", "subtype": "stop_hook_summary", "parentUuid": "terminal",
                      "timestamp": "2026-10-04T03:00:05Z"])
    check(unanchored.completion == nil, "Claude estimate: tail without observed input ancestry invented request start")

    // Waiting for the person: a pending question never goes stale, but is capped at 24 hours.
    let asking = TokenLogParser(source: .claude)
    let askStart = ISO8601DateFormatter().date(from: "2026-10-04T09:00:00Z")!
    feed(asking, claudeUser("k-in", "2026-10-04T09:00:00Z", content: "plan", extra: ["origin": ["kind": "human"]]))
    feed(asking, claudeReply("k-msg", 20, "2026-10-04T09:00:01Z", "k-out",
                             blocks: [["type": "tool_use", "id": "k-bash", "name": "Bash", "input": ["command": "PRIVATE_INPUT"]]]))
    check(asking.activityState(at: askStart.addingTimeInterval(2)) == .tool && asking.runningTool?.name == "Bash"
          && TokenLogParser.category("Bash") == .command,
          "Input state: a running command was not named by its tool category")
    feed(asking, claudeReply("k-ask", 10, "2026-10-04T09:00:02Z", "k-ask",
                             blocks: [["type": "tool_use", "id": "k-question", "name": "AskUserQuestion"]]))
    check(asking.activityState(at: askStart.addingTimeInterval(3_600)) == .input
          && asking.isActive(at: askStart.addingTimeInterval(3_600)) && asking.runningTool?.name == "AskUserQuestion",
          "Input state: a pending question must stay waiting-for-input instead of becoming log-waiting")
    check(asking.activityState(at: askStart.addingTimeInterval(86_500)) == .unfinished
          && !asking.isActive(at: askStart.addingTimeInterval(86_500)),
          "Input state: a question with no log for over 24 hours must become unfinished")
    feed(asking, claudeUser("k-answer", "2026-10-04T09:05:00Z",
                            content: [["type": "tool_result", "tool_use_id": "k-question"]]))
    check(asking.activityState(at: askStart.addingTimeInterval(301)) == .tool && asking.runningTool?.name == "Bash",
          "Input state: answering the question must return to the still-running tool")
    let planning = TokenLogParser(source: .claude)
    feed(planning, claudeUser("pl-in", "2026-10-04T09:00:00Z", content: "plan", extra: ["origin": ["kind": "human"]]))
    feed(planning, claudeReply("pl-msg", 5, "2026-10-04T09:00:01Z", "pl-out",
                               blocks: [["type": "tool_use", "id": "pl-exit", "name": "ExitPlanMode"]]))
    check(planning.activityState(at: askStart.addingTimeInterval(1_200)) == .input,
          "Input state: a pending plan approval must wait for the person")
    let mixed = TokenLogParser(source: .claude)
    feed(mixed, claudeUser("mx-in", "2026-10-04T09:00:00Z", content: "go", extra: ["origin": ["kind": "human"]]))
    feed(mixed, claudeReply("mx-msg", 5, "2026-10-04T09:00:01Z", "mx-out",
                            blocks: [["type": "tool_use", "id": "mx-ask", "name": "AskUserQuestion"],
                                     ["type": "tool_use", "id": "mx-bash", "name": "Bash"]]))
    check(mixed.activityState(at: askStart.addingTimeInterval(60)) == .input && mixed.runningTool?.name == "AskUserQuestion",
          "Input state: a question pending beside another tool must name the question, not the other tool")
    let categories: [(String, ToolCategory)] = [("exec", .command), ("js", .command), ("apply_patch", .file),
        ("Read", .file), ("WebFetch", .web), ("Agent", .agent), ("wait_agent", .agent), ("mcp__srv__tool", .mcp),
        ("request_user_input_async", .question), ("Monitor", .other)]
    check(categories.allSatisfy { TokenLogParser.category($0.0) == $0.1 }, "Tool names mapped to the wrong category")

    // Claude API retries keep counts, delay and the network flag; never the error text.
    let retrying = TokenLogParser(source: .claude)
    feed(retrying, claudeUser("rt-in", "2026-10-04T09:10:00Z", content: "go", extra: ["origin": ["kind": "human"]]))
    feed(retrying, ["type": "system", "subtype": "api_error", "uuid": "rt-1", "timestamp": "2026-10-04T09:10:05Z",
                    "retryAttempt": 3, "maxRetries": 10, "retryInMs": 4_000,
                    "error": ["isNetworkDown": true, "message": "PRIVATE_ERROR", "formatted": "PRIVATE_ERROR"]])
    let retryAt = ISO8601DateFormatter().date(from: "2026-10-04T09:10:09Z")!
    check(retrying.retry == TokenRetryState(attempt: 3, maxAttempts: 10, retryAt: retryAt, networkDown: true,
                                            at: retryAt.addingTimeInterval(-4))
          && !String(reflecting: retrying.retry).contains("PRIVATE"),
          "API retry: attempt, limit, retry time or network state was lost, or message text was kept")
    feed(retrying, claudeReply("rt-msg", 12, "2026-10-04T09:10:20Z", "rt-out", blocks: [["type": "thinking"]]))
    check(retrying.retry == nil, "API retry: a successful response must clear the retry state")
    feed(retrying, ["type": "system", "subtype": "api_error", "uuid": "rt-2", "timestamp": "2026-10-04T09:10:30Z",
                    "retryAttempt": 1, "maxRetries": 10, "retryInMs": 500, "error": ["isNetworkDown": false]])
    feed(retrying, ["type": "system", "subtype": "stop_hook_summary", "uuid": "rt-end", "timestamp": "2026-10-04T09:10:40Z"])
    check(retrying.retry == nil, "API retry: turn end must clear the retry state")

    // Codex usage limit and context: newest own record wins; forked replays never count.
    func limited(_ timestamp: String, used: Double, resets: Int, input: Int, limit: String = "codex") -> [String: Any] {
        codex("token_count", timestamp, [
            "info": ["total_token_usage": ["output_tokens": 10], "last_token_usage": ["output_tokens": 10, "input_tokens": input],
                     "model_context_window": 258_400],
            "rate_limits": ["limit_id": limit, "primary": ["used_percent": used, "window_minutes": 10_080, "resets_at": resets],
                            "secondary": NSNull(), "credits": ["balance": "PRIVATE_BALANCE"]]])
    }
    let usageLimits = TokenLogParser(source: .codex)
    feed(usageLimits, ["type": "session_meta", "payload": ["id": "limit-fork", "timestamp": "2026-10-04T10:00:00Z",
        "agent_nickname": "Nick Name", "source": ["subagent": ["thread_spawn": ["agent_role": "explorer", "parent_thread_id": "p"]]]]])
    feed(usageLimits, ["type": "compacted", "timestamp": "2026-10-04T10:00:00Z", "payload": ["window_number": 2]])
    feed(usageLimits, limited("2026-10-04T10:00:00Z", used: 90, resets: 1_791_200_000, input: 200_000))
    feed(usageLimits, codex("task_started", "2026-10-04T10:00:00Z", ["turn_id": "parent", "started_at": "2026-10-04T09:00:00Z"]))
    feed(usageLimits, limited("2026-10-04T10:00:00.500Z", used: 91, resets: 1_791_200_000, input: 210_000))
    feed(usageLimits, codex("task_complete", "2026-10-04T10:00:01Z", ["turn_id": "parent", "duration_ms": 60_000]))
    check(usageLimits.rateLimit == nil && usageLimits.context == nil && usageLimits.lastTurnDuration == nil,
          "Codex snapshots: a forked log's replayed parent limit, context, compaction or duration was kept")
    feed(usageLimits, ["type": "turn_context", "timestamp": "2026-10-04T10:00:02Z", "payload": ["model": "own-model",
        "turn_id": "own", "cwd": "/tmp/Fixture/LimitProject", "collaboration_mode": ["settings": ["reasoning_effort": "xhigh"]]]])
    feed(usageLimits, codex("task_started", "2026-10-04T10:00:02Z", ["turn_id": "own"]))
    feed(usageLimits, limited("2026-10-04T10:00:05Z", used: 28.5, resets: 1_791_300_000, input: 120_000))
    feed(usageLimits, limited("2026-10-04T10:00:04Z", used: 99, resets: 1_791_300_000, input: 999_000))
    feed(usageLimits, limited("2026-10-04T10:00:06Z", used: 1, resets: 1_791_300_000, input: 1, limit: "premium"))
    feed(usageLimits, ["type": "compacted", "timestamp": "2026-10-04T10:00:07Z", "payload": ["window_number": 3]])
    let limitAt = ISO8601DateFormatter().date(from: "2026-10-04T10:00:05Z")!
    check(usageLimits.rateLimit == TokenRateLimit(usedPercent: 28.5, windowMinutes: 10_080,
              resetsAt: Date(timeIntervalSince1970: 1_791_300_000), recordedAt: limitAt),
          "Codex usage limit: the newest own record must win over older, other-limit or replayed records")
    check(usageLimits.context?.usedTokens == 1 && usageLimits.context?.windowTokens == 258_400
          && usageLimits.context?.compactedAt == limitAt.addingTimeInterval(2),
          "Codex context: the newest input count, its window or the own compaction time was lost")
    check(usageLimits.effort == "xhigh" && usageLimits.agentRole == "explorer" && usageLimits.model == "own-model"
          && usageLimits.projectPath == "/tmp/Fixture/LimitProject" && usageLimits.project == "LimitProject",
          "Codex metadata: effort, subagent role or the full project path was not kept")
    let corrupt = TokenLogParser(source: .claude)
    feed(corrupt, ["type": "user", "uuid": "huge-in", "timestamp": "2026-10-04T10:00:00Z", "origin": ["kind": "human"],
                   "message": ["content": "go"]])
    feed(corrupt, ["type": "system", "subtype": "api_error", "timestamp": "2026-10-04T10:00:01Z", "retryAttempt": 1, "retryInMs": 1e25])
    check(corrupt.retry != nil && corrupt.retry?.retryAt == nil, "An out-of-range retry delay was kept")
    feed(corrupt, ["type": "system", "subtype": "turn_duration", "timestamp": "2026-10-04T10:00:02Z", "durationMs": 1e22])
    check(corrupt.lastTurnDuration == nil, "An out-of-range turn duration was kept and could trap integer formatting")
    let twoWindows = TokenLogParser(source: .codex)
    feed(twoWindows, codex("task_started", "2026-10-04T10:00:00Z", ["turn_id": "own"]))
    feed(twoWindows, codex("token_count", "2026-10-04T10:00:01Z", ["rate_limits": ["limit_id": "codex",
        "primary": ["used_percent": 20, "window_minutes": 300, "resets_at": 1_791_100_000],
        "secondary": ["used_percent": 97, "window_minutes": 10_080, "resets_at": 1_791_500_000]]]))
    check(twoWindows.rateLimit?.usedPercent == 97 && twoWindows.rateLimit?.windowMinutes == 10_080,
          "Codex usage limit: a near-full weekly secondary window was hidden behind the 5-hour primary")
    let review = TokenLogParser(source: .codex)
    feed(review, ["type": "session_meta", "payload": ["id": "review", "source": ["subagent": ["other": "guardian"]]]])
    feed(review, ["type": "turn_context", "payload": ["model": "m", "effort": "low"]])
    check(review.agentRole == "guardian" && review.effort == "low",
          "Codex metadata: an automatic review thread or a plain effort field was not labelled")
    let compactedClaude = TokenLogParser(source: .claude)
    feed(compactedClaude, assistant("cc-a", 10, "2026-10-04T11:00:00Z", "cc-a"))
    feed(compactedClaude, ["type": "system", "subtype": "compact_boundary", "uuid": "cc-b", "timestamp": "2026-10-04T11:01:00Z",
                           "compactMetadata": ["trigger": "auto", "preTokens": 900_000, "durationMs": 90_000]])
    check(compactedClaude.context?.compactedAt == ISO8601DateFormatter().date(from: "2026-10-04T11:01:00Z")
          && compactedClaude.context?.usedTokens == 150_000,
          "Claude context: the compaction boundary time was not recorded")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenCat-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let folder = root.appendingPathComponent(".codex/sessions/2026/10/04")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a.jsonl")
        let b = folder.appendingPathComponent("b.jsonl")
        var fixture = line(["type": "session_meta", "payload": ["id": "session-a", "cwd": "/tmp/ProjectA"]])
        fixture.append(line(["type": "turn_context", "payload": ["model": "model-a"]]))
        fixture.append(line(codex("task_started", "2026-10-04T04:00:00Z", ["turn_id": "a"])))
        fixture.append(line(usage(100, 100, "2026-10-04T04:00:01Z")))
        let ending = line(codex("task_complete", "2026-10-04T04:00:02Z", ["turn_id": "a", "duration_ms": 2_000]))
        fixture.append(ending.prefix(ending.count / 2))
        try fixture.write(to: a)
        var other = line(["type": "session_meta", "payload": ["id": "session-b", "cwd": "/tmp/ProjectB"]])
        other.append(line(["type": "turn_context", "payload": ["model": "model-b"]]))
        other.append(line(codex("task_started", "2026-10-04T04:00:00Z", ["turn_id": "b"])))
        other.append(line(usage(20, 20, "2026-10-04T04:00:01Z")))
        try other.write(to: b)
        let now = ISO8601DateFormatter().date(from: "2026-10-04T04:00:03Z")!
        let tracker = TokenTracker(homeDirectory: root, now: { now }, discoveryInterval: 0)
        let first = tracker.sample()
        check(first.count == 2 && first.allSatisfy { $0.active && $0.lastOutputTokens == nil && $0.lastTurnDurationSeconds == nil },
              "Partial JSONL or simultaneous sessions were combined")
        check(Set(first.map(\.id)).count == 2 && Set(first.compactMap(\.model)) == ["model-a", "model-b"],
              "Concurrent sessions lost their separate stable IDs or models")
        check(Set(first.compactMap(\.project)) == ["ProjectA", "ProjectB"], "Session project metadata was not retained")
        let append = try FileHandle(forWritingTo: a)
        try append.seekToEnd()
        try append.write(contentsOf: ending.suffix(ending.count - ending.count / 2))
        try append.close()
        let second = tracker.sample()
        check(second.first?.sessionID == "session-b" && second.first?.active == true
              && second.first?.lastOutputTokens == nil
              && second.first(where: { $0.sessionID == "session-a" })?.lastTurnDurationSeconds == 2
              && second.first(where: { $0.sessionID == "session-a" })?.lastOutputTokens == 100,
              "Active session inherited another session's completion, or active-first sorting failed")
        check(Set(first.map(\.id)) == Set(second.map(\.id)), "Incremental updates changed session identity")
        let endingB = line(codex("task_complete", "2026-10-04T04:00:03Z", ["turn_id": "b", "duration_ms": 2_000]))
        let appendB = try FileHandle(forWritingTo: b)
        try appendB.seekToEnd()
        try appendB.write(contentsOf: endingB)
        try appendB.close()
        let third = tracker.sample()[0]
        check(third.lastTurnDurationSeconds == 2 && third.lastOutputTokens == 20,
              "Incremental completion selected incorrect simultaneous session")
        let repeatSample = tracker.sample()[0]
        check(repeatSample.lastOutputTokens == 20, "Repeated file sample duplicated output")
        try Data("{}\n".utf8).write(to: b)
        let truncated = tracker.sample()[0]
        check(truncated.lastTurnDurationSeconds == 2 && truncated.lastOutputTokens == 100,
              "Truncated file kept stale usage state")

        let modelUpdate = try FileHandle(forWritingTo: a)
        try modelUpdate.seekToEnd()
        try modelUpdate.write(contentsOf: line(["type": "turn_context", "payload": ["model": "model-a-new"]]))
        try modelUpdate.write(contentsOf: line(codex("task_started", "2026-10-04T04:00:03Z", ["turn_id": "a-next"])))
        try modelUpdate.close()
        let switched = tracker.sample().first(where: { $0.sessionID == "session-a" })
        check(switched?.model == "model-a-new" && switched?.measurementModel == "model-a"
              && switched?.lastOutputTokens == 100,
              "Changing the current model reassigned an earlier measurement to the new model")
        check(TokenTracker(homeDirectory: root.appendingPathComponent("empty"), now: { now }).sample().isEmpty,
              "An empty log directory fabricated provider rows")

        let claudeProject = root.appendingPathComponent(".claude/projects/fixture-project")
        let subagentFolder = claudeProject.appendingPathComponent("shared/subagents")
        try FileManager.default.createDirectory(at: subagentFolder, withIntermediateDirectories: true)
        for isAgent in [false, true] {
            var input: [String: Any] = ["type": "user", "uuid": "input-\(isAgent)",
                "timestamp": "2026-10-04T04:00:00Z", "sessionId": "shared-session",
                "cwd": "/tmp/ClaudeProject", "isSidechain": isAgent,
                "message": ["content": [["type": "text"]]]]
            if isAgent { input["agentId"] = "worker-one" }
            var out = assistant("out-\(isAgent)", isAgent ? 20 : 60, "2026-10-04T04:00:01Z", "uuid-\(isAgent)")
            out["sessionId"] = "shared-session"
            out["isSidechain"] = isAgent
            var message = out["message"] as! [String: Any]
            message["model"] = isAgent ? "claude-worker" : "claude-main"
            out["message"] = message
            if isAgent { out["agentId"] = "worker-one" }
            let duration: [String: Any] = ["type": "system", "subtype": "turn_duration",
                "parentUuid": "uuid-\(isAgent)", "timestamp": "2026-10-04T04:00:02Z",
                "durationMs": 2_000, "isSidechain": isAgent]
            var body = line(input)
            body.append(line(out))
            body.append(line(duration))
            if !isAgent {
                var foreign = assistant("foreign", 999, "2026-10-04T04:00:03Z", "foreign")
                foreign["isSidechain"] = true
                body.append(line(foreign))
            }
            try body.write(to: isAgent ? subagentFolder.appendingPathComponent("agent-worker.jsonl")
                               : claudeProject.appendingPathComponent("shared.jsonl"))
        }
        try line(["agentType": "workflow-subagent", "description": "PRIVATE_TASK", "worktreePath": "/tmp/PRIVATE_PATH",
                  "spawnDepth": 1]).write(to: subagentFolder.appendingPathComponent("agent-worker.meta.json"))
        let claudeSessions = tracker.sample().filter { $0.source == .claude }
        let encodedSessions = String(decoding: (try? JSONEncoder().encode(claudeSessions)) ?? Data(), as: UTF8.self)
        check(claudeSessions.first(where: { $0.isSubagent })?.agentRole == "workflow-subagent"
              && claudeSessions.first(where: { !$0.isSubagent })?.agentRole == nil && !encodedSessions.contains("PRIVATE"),
              "Claude subagent sidecar: agentType was not kept, or another sidecar key leaked")
        check(claudeSessions.allSatisfy { $0.projectPath == "/tmp/ClaudeProject" && $0.project == "ClaudeProject" },
              "Claude project path was not kept alongside the project name")
        check(claudeSessions.count == 2 && Set(claudeSessions.map(\.id)).count == 2,
              "Claude main and subagent with the same sessionId were merged or omitted")
        check(claudeSessions.first(where: { $0.isSubagent })?.lastOutputTokens == 20
              && claudeSessions.first(where: { !$0.isSubagent })?.lastOutputTokens == 60
              && claudeSessions.allSatisfy { $0.lastTurnDurationSeconds == 2 },
              "Claude nested sidechain usage leaked into the main log, or was ignored in the child log")
        check(Set(claudeSessions.compactMap(\.model)) == ["claude-main", "claude-worker"],
              "Claude main/subagent model identity was overwritten by sidechain records")
        let workflowFolder = subagentFolder.appendingPathComponent("workflows/fixture-workflow")
        try FileManager.default.createDirectory(at: workflowFolder, withIntermediateDirectories: true)
        let workerBody = try String(contentsOf: subagentFolder.appendingPathComponent("agent-worker.jsonl"), encoding: .utf8)
            .replacingOccurrences(of: "worker-one", with: "worker-two")
            .replacingOccurrences(of: "claude-worker", with: "claude-workflow")
        try workerBody.write(to: workflowFolder.appendingPathComponent("agent-workflow.jsonl"), atomically: true, encoding: .utf8)
        let workflowSessions = tracker.sample().filter { $0.source == .claude }
        check(workflowSessions.count == 3 && workflowSessions.contains(where: {
            $0.isSubagent && $0.agentID == "worker-two" && $0.model == "claude-workflow" && $0.lastOutputTokens == 20
        }), "Claude workflow-nested subagent was not discovered or lost its sidechain identity")

        // Begin reading within a large line: suffixes and unseen turn starts cannot produce rates.
        var large = Data(repeating: 32, count: 2_048)
        large.append(10)
        large.append(line(usage(800, 100, "2026-10-04T04:00:04Z")))
        large.append(line(codex("task_complete", "2026-10-04T04:00:05Z", ["turn_id": "unseen", "duration_ms": 1_000])))
        try large.write(to: a)
        let bounded = TokenTracker(homeDirectory: root, now: { now }, initialTailBytes: 256)
        check(bounded.sample().filter { $0.source == .codex }.allSatisfy { $0.lastOutputTokens == nil && $0.lastTurnDurationSeconds == nil },
              "Initial bounded tail attributed an unseen turn's output or duration")

        // A bounded tail can still recover identity/project from the metadata-only header.
        let headerHome = root.appendingPathComponent("header")
        let headerFolder = headerHome.appendingPathComponent(".codex/sessions/2026/10/04")
        try FileManager.default.createDirectory(at: headerFolder, withIntermediateDirectories: true)
        var header = line(["type": "session_meta", "payload": ["id": "header-session", "cwd": "/tmp/HeaderProject"]])
        header.append(line(["type": "turn_context", "payload": ["model": "stale-header-model"]]))
        header.append(Data(repeating: 32, count: 2_048))
        header.append(10)
        header.append(line(["type": "turn_context", "payload": ["model": "fresh-tail-model"]]))
        header.append(line(codex("task_started", "2026-10-04T04:00:01Z", ["turn_id": "header-turn"])))
        try header.write(to: headerFolder.appendingPathComponent("header.jsonl"))
        let headerReading = TokenTracker(homeDirectory: headerHome, now: { now }, initialTailBytes: 512).sample().first
        check(headerReading?.sessionID == "header-session" && headerReading?.project == "HeaderProject",
              "Bounded tail lost session/project metadata from the initial header")
        check(headerReading?.model == "fresh-tail-model" && headerReading?.lastOutputTokens == nil,
              "Metadata header replayed an old model or lifecycle/usage")

        let longHome = root.appendingPathComponent("long-open-turn")
        let longFolder = longHome.appendingPathComponent(".codex/sessions/2026/10/04")
        try FileManager.default.createDirectory(at: longFolder, withIntermediateDirectories: true)
        let longFile = longFolder.appendingPathComponent("long.jsonl")
        var longBody = line(["type": "session_meta", "payload": ["id": "long-session", "cwd": "/tmp/LongProject",
            "timestamp": "2026-10-04T04:00:00Z"]])
        longBody.append(line(codex("task_started", "2026-10-04T04:00:01Z", ["turn_id": "long-turn"])))
        longBody.append(line(["type": "turn_context", "timestamp": "2026-10-04T04:00:01Z",
            "payload": ["model": "long-model", "turn_id": "long-turn", "cwd": "/tmp/CurrentProject"]]))
        longBody.append(Data(repeating: 32, count: 4_096))
        longBody.append(10)
        longBody.append(line(usage(50, 50, "2026-10-04T04:00:03Z")))
        try longBody.write(to: longFile)
        let longNow = ISO8601DateFormatter().date(from: "2026-10-04T04:00:08Z")!
        let longTracker = TokenTracker(homeDirectory: longHome, now: { longNow }, initialTailBytes: 512)
        let openLong = longTracker.sample().first
        check(openLong?.model == "long-model" && openLong?.project == "CurrentProject"
              && openLong?.active == true && openLong?.lastOutputTokens == nil,
              "Starting mid-turn lost current model/activity or fabricated a partial turn output")
        check(openLong?.currentTurnStartedAt == ISO8601DateFormatter().date(from: "2026-10-04T04:00:01Z")
              && openLong?.currentTurnOutputTokens == nil && openLong?.activityState == .working
              && openLong?.lastOutputDelta == 50 && openLong?.sampledAt == longNow,
              "Restored live metadata must expose elapsed time and observed delta without inventing a whole-turn output count")
        let longAppend = try FileHandle(forWritingTo: longFile)
        try longAppend.seekToEnd()
        try longAppend.write(contentsOf: line(codex("task_complete", "2026-10-04T04:00:04Z",
            ["turn_id": "long-turn", "duration_ms": 3_000])))
        let closedLong = longTracker.sample().first
        check(closedLong?.active == false && closedLong?.lastOutputTokens == nil && closedLong?.lastTurnDurationSeconds == 3,
              "A metadata-only open turn stayed active, reported a partial output, or lost its own reported duration")
        check(closedLong?.activityState == .complete && closedLong?.currentTurnStartedAt == nil
              && closedLong?.currentTurnOutputTokens == nil,
              "A restored live turn's completion must close state without a partial-rate accumulator")
        // A Codex turn whose start is outside the tail still reports its recorded total.
        for (name, usageInTail) in [("usage-in-tail", true), ("usage-before-tail", false)] {
            let usageHome = root.appendingPathComponent(name)
            let usageFolder = usageHome.appendingPathComponent(".codex/sessions/2026/10/04")
            try FileManager.default.createDirectory(at: usageFolder, withIntermediateDirectories: true)
            var usageBody = line(["type": "session_meta", "payload": ["id": name, "timestamp": "2026-10-04T04:00:00Z"]])
            usageBody.append(line(codex("task_started", "2026-10-04T04:00:01Z", ["turn_id": "restored-turn"])))
            usageBody.append(line(["type": "turn_context", "timestamp": "2026-10-04T04:00:01Z",
                "payload": ["model": "usage-model", "turn_id": "restored-turn"]]))
            let record = line(usageRecord("restored-resp", turn: "restored-turn", output: 300, turnTotal: 5_300,
                                          "2026-10-04T04:00:06Z"))
            if !usageInTail { usageBody.append(record) }
            usageBody.append(Data(repeating: 32, count: 4_096))
            usageBody.append(10)
            if usageInTail { usageBody.append(record) }
            try usageBody.write(to: usageFolder.appendingPathComponent("\(name).jsonl"))
            let restored = TokenTracker(homeDirectory: usageHome, now: { longNow }, initialTailBytes: 512).sample().first
            check(restored?.active == true && restored?.currentTurnOutputTokens == 5_300
                  && restored?.currentTurnStartedAt == ISO8601DateFormatter().date(from: "2026-10-04T04:00:01Z"),
                  "Codex usage record (\(name)): a turn started outside the tail lost its recorded cumulative output")
        }

        // A long Claude turn whose human input precedes the tail is read from that input.
        let claudeLongHome = root.appendingPathComponent("claude-long-turn")
        let claudeLongFolder = claudeLongHome.appendingPathComponent(".claude/projects/long")
        try FileManager.default.createDirectory(at: claudeLongFolder, withIntermediateDirectories: true)
        func compact(_ value: [String: Any]) -> Data {
            var data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            data.append(10)
            return data
        }
        var openTurn = compact(["type": "user", "uuid": "long-human", "timestamp": "2026-10-04T04:00:00Z",
                                "sessionId": "long-claude", "message": ["content": [["type": "text"]]]])
        openTurn.append(compact(assistant("long-1", 400, "2026-10-04T04:00:01Z", "long-a")))
        openTurn.append(Data(repeating: 32, count: 4_096))
        openTurn.append(10)
        openTurn.append(compact(assistant("long-2", 50, "2026-10-04T04:00:07Z", "long-b")))
        try openTurn.write(to: claudeLongFolder.appendingPathComponent("open.jsonl"))
        var closedTurn = compact(["type": "user", "uuid": "closed-human", "timestamp": "2026-10-04T03:59:00Z",
                                  "sessionId": "closed-claude", "message": ["content": [["type": "text"]]]])
        closedTurn.append(compact(assistant("closed-1", 100, "2026-10-04T03:59:01Z", "closed-a")))
        closedTurn.append(compact(["type": "system", "subtype": "stop_hook_summary", "parentUuid": "closed-a",
                                   "timestamp": "2026-10-04T03:59:02Z"]))
        closedTurn.append(Data(repeating: 32, count: 4_096))
        closedTurn.append(10)
        try closedTurn.write(to: claudeLongFolder.appendingPathComponent("closed.jsonl"))
        let claudeLong = TokenTracker(homeDirectory: claudeLongHome, now: { longNow }, initialTailBytes: 512).sample()
        let openClaude = claudeLong.first(where: { $0.sessionID == "long-claude" })
        check(openClaude?.active == true && openClaude?.currentTurnOutputTokens == 450
              && openClaude?.currentTurnStartedAt == ISO8601DateFormatter().date(from: "2026-10-04T04:00:00Z"),
              "Claude long turn: output before the tail was reported unknown instead of read from the human input")
        check(!claudeLong.contains(where: { $0.sessionID == "closed-claude" }),
              "Claude long turn: a closed turn before the tail was replayed")

        let abortedHome = root.appendingPathComponent("restored-interruption")
        let abortedFolder = abortedHome.appendingPathComponent(".codex/sessions/2026/10/04")
        try FileManager.default.createDirectory(at: abortedFolder, withIntermediateDirectories: true)
        var abortedBody = line(["type": "session_meta", "payload": ["id": "aborted-session",
            "timestamp": "2026-10-04T04:00:00Z"]])
        abortedBody.append(line(codex("task_started", "2026-10-04T04:00:00Z", ["turn_id": "aborted-turn"])))
        abortedBody.append(line(["type": "turn_context", "timestamp": "2026-10-04T04:00:00Z",
            "payload": ["model": "aborted-model", "turn_id": "aborted-turn"]]))
        abortedBody.append(line(codex("turn_aborted", "2026-10-04T04:00:02Z", ["turn_id": "aborted-turn"])))
        abortedBody.append(Data(repeating: 32, count: 4_096))
        abortedBody.append(10)
        try abortedBody.write(to: abortedFolder.appendingPathComponent("aborted.jsonl"))
        let restoredAbort = TokenTracker(homeDirectory: abortedHome, now: { longNow }, initialTailBytes: 512).sample().first
        check(restoredAbort?.activityState == .interrupted && restoredAbort?.active == false
              && restoredAbort?.currentTurnStartedAt == nil && restoredAbort?.currentTurnOutputTokens == nil,
              "A metadata-restored aborted Codex turn was presented as completed")
        try longAppend.write(contentsOf: line(codex("task_started", "2026-10-04T04:00:05Z", ["turn_id": "complete-turn"])))
        try longAppend.write(contentsOf: line(usage(70, 20, "2026-10-04T04:00:06Z")))
        try longAppend.write(contentsOf: line(codex("task_complete", "2026-10-04T04:00:07Z",
            ["turn_id": "complete-turn", "duration_ms": 2_000])))
        try longAppend.close()
        check(longTracker.sample().first.map { $0.lastOutputTokens == 20 && $0.lastTurnDurationSeconds == 2 } == true,
              "The next fully observed turn did not recover its output and duration")

        // Forked logs can put the inherited opener outside the initial tail.
        let inheritedHome = root.appendingPathComponent("long-inherited-turn")
        let inheritedFolder = inheritedHome.appendingPathComponent(".codex/sessions/2026/10/04")
        try FileManager.default.createDirectory(at: inheritedFolder, withIntermediateDirectories: true)
        let inheritedFile = inheritedFolder.appendingPathComponent("child.jsonl")
        var inheritedBody = line(["type": "session_meta", "payload": ["id": "child-session",
            "cwd": "/tmp/ChildProject", "timestamp": "2026-10-04T04:00:10Z",
            "source": ["subagent": ["agent_path": "worker"]]]])
        inheritedBody.append(line(codex("task_started", "2026-10-04T04:00:11Z",
            ["turn_id": "parent-turn", "started_at": "2026-10-04T04:00:00Z"])))
        inheritedBody.append(line(["type": "turn_context", "timestamp": "2026-10-04T04:00:11Z",
            "payload": ["model": "parent-model", "turn_id": "parent-turn", "cwd": "/tmp/ParentProject"]]))
        inheritedBody.append(Data(repeating: 32, count: 4_096))
        inheritedBody.append(10)
        inheritedBody.append(line(usage(100, 100, "2026-10-04T04:00:12Z")))
        inheritedBody.append(line(codex("task_complete", "2026-10-04T04:00:13Z",
            ["turn_id": "parent-turn", "duration_ms": 3_000])))
        try inheritedBody.write(to: inheritedFile)
        let inheritedNow = ISO8601DateFormatter().date(from: "2026-10-04T04:00:18Z")!
        let inheritedTracker = TokenTracker(homeDirectory: inheritedHome, now: { inheritedNow }, initialTailBytes: 512)
        check(inheritedTracker.sample().isEmpty,
              "Bounded metadata recovery restored inherited parent model, activity, or output in the child")
        let inheritedAppend = try FileHandle(forWritingTo: inheritedFile)
        try inheritedAppend.seekToEnd()
        try inheritedAppend.write(contentsOf: line(["type": "turn_context", "timestamp": "2026-10-04T04:00:14Z",
            "payload": ["model": "child-model", "turn_id": "child-turn", "cwd": "/tmp/ChildProject"]]))
        try inheritedAppend.write(contentsOf: line(codex("task_started", "2026-10-04T04:00:14Z", ["turn_id": "child-turn"])))
        try inheritedAppend.write(contentsOf: line(usage(120, 20, "2026-10-04T04:00:14.500Z")))
        try inheritedAppend.write(contentsOf: line(codex("task_complete", "2026-10-04T04:00:15Z",
            ["turn_id": "child-turn", "duration_ms": 1_000])))
        try inheritedAppend.close()
        let recoveredChild = inheritedTracker.sample().first
        check(recoveredChild?.model == "child-model" && recoveredChild?.project == "ChildProject"
              && recoveredChild?.lastTurnDurationSeconds == 1 && recoveredChild?.lastOutputTokens == 20,
              "A child turn after bounded inherited history failed to restore its own model and measurement")
        check(recoveredChild?.lastOutputDelta == 20 && recoveredChild?.activityState == .complete,
              "Inherited parent output delta or activity leaked into a child live row")

        let newSessionHome = root.appendingPathComponent("new-session-discovery")
        let newSessionFolder = newSessionHome.appendingPathComponent(".codex/sessions/2026/10/04")
        try FileManager.default.createDirectory(at: newSessionFolder, withIntermediateDirectories: true)
        var discoveryNow = longNow
        let newSessionTracker = TokenTracker(homeDirectory: newSessionHome, now: { discoveryNow })
        check(newSessionTracker.sample().isEmpty, "An empty home fabricated live placeholder sessions")
        let newlyStartedFile = newSessionFolder.appendingPathComponent("new.jsonl")
        try line(codex("task_started", "2026-10-04T04:00:10Z", ["turn_id": "new-session"])).write(to: newlyStartedFile)
        discoveryNow = longNow.addingTimeInterval(5)
        let newlyDiscovered = newSessionTracker.sample().first
        check(newlyDiscovered?.activityState == .working && newlyDiscovered?.currentTurnOutputTokens == 0
              && newlyDiscovered?.sampledAt == discoveryNow,
              "Default discovery must collect a new observed session within five seconds")

        // Appends wake sampling through file-system events, and stop() ends callbacks.
        let watchRoot = root.appendingPathComponent("watch/.codex/sessions")
        try FileManager.default.createDirectory(at: watchRoot, withIntermediateDirectories: true)
        let woke = DispatchSemaphore(value: 0)
        let watchedFile = watchRoot.appendingPathComponent("live.jsonl")
        let watcher = LogWatcher { paths in
            if paths.contains(where: { $0.hasSuffix("/live.jsonl") }) { woke.signal() }
        }
        check(watcher.start(directories: [watchRoot, root.appendingPathComponent("missing")]),
              "Log watcher could not watch an existing log directory")
        let written = Date()
        try line(codex("task_started", "2026-10-04T04:00:00Z", ["turn_id": "watched"])).write(to: watchedFile)
        let wokeInTime = woke.wait(timeout: .now() + 3) == .success
        check(wokeInTime && Date().timeIntervalSince(written) < 1.5,
              "Log watcher did not report a log write within 1.5 s")
        watcher.stop()
        while woke.wait(timeout: .now() + 0.3) == .success {}
        try line(usage(10, 10, "2026-10-04T04:00:01Z")).write(to: watchedFile)
        check(woke.wait(timeout: .now() + 0.6) == .timedOut, "Log watcher delivered events after stop()")
        check(!LogWatcher { _ in }.start(directories: [root.appendingPathComponent("missing")]),
              "Log watcher claimed to watch a missing directory")

        // A forked Codex log replays the parent's session_meta and open turn after its own.
        let forkHome = root.appendingPathComponent("fork")
        let forkFolder = forkHome.appendingPathComponent(".codex/sessions/2026/10/04")
        try FileManager.default.createDirectory(at: forkFolder, withIntermediateDirectories: true)
        let childID = "0000c41d-0000-7000-8000-00000000c41d"
        let rootID = "0000a007-0000-7000-8000-00000000a007"
        var forkBody = line(["type": "session_meta", "timestamp": "2026-10-04T06:54:35Z", "payload": [
            "id": childID, "session_id": rootID, "timestamp": "2026-10-04T06:54:35Z", "cwd": "/tmp/ForkProject",
            "agent_path": "/root/worker", "source": ["subagent": ["thread_spawn": ["parent_thread_id": rootID]]]]])
        forkBody.append(line(["type": "session_meta", "timestamp": "2026-10-04T06:54:35Z", "payload": [
            "id": rootID, "session_id": rootID, "timestamp": "2026-10-04T03:43:12Z", "cwd": "/tmp/ParentProject", "source": "vscode"]]))
        forkBody.append(line(codex("task_started", "2026-10-04T06:54:35Z", ["turn_id": "parent-open", "started_at": 1_791_090_000])))
        forkBody.append(line(codex("task_started", "2026-10-04T06:54:36Z", ["turn_id": "child-own"])))
        forkBody.append(line(usageRecord("child-resp", turn: "child-own", output: 161, turnTotal: 161, "2026-10-04T06:54:41Z")))
        try forkBody.write(to: forkFolder.appendingPathComponent("rollout-2026-10-04T06-54-35-\(childID).jsonl"))
        let forkNow = ISO8601DateFormatter().date(from: "2026-10-04T06:54:45Z")!
        let forkReading = TokenTracker(homeDirectory: forkHome, now: { forkNow }).sample().first
        check(forkReading?.sessionID == childID && forkReading?.parentSessionID == rootID && forkReading?.isSubagent == true
              && forkReading?.project == "ForkProject",
              "Forked Codex log: the replayed parent session_meta replaced the child's identity")
        check(forkReading?.currentTurnOutputTokens == 161
              && forkReading?.currentTurnStartedAt == ISO8601DateFormatter().date(from: "2026-10-04T06:54:36Z"),
              "Forked Codex log: the inherited parent turn was treated as the child's own")

        // A quiet main session in a turn survives a burst of newer logs.
        let retainHome = root.appendingPathComponent("retain")
        let retainFolder = retainHome.appendingPathComponent(".claude/projects/busy")
        try FileManager.default.createDirectory(at: retainFolder, withIntermediateDirectories: true)
        let quiet = retainFolder.appendingPathComponent("quiet.jsonl")
        var quietBody = line(claudeUser("q-in", "2026-10-04T04:00:00Z", content: "long job",
                                        extra: ["sessionId": "quiet", "origin": ["kind": "human"]]))
        quietBody.append(line(claudeReply("q-msg", 10, "2026-10-04T04:00:01Z", "q-out", blocks: [["type": "tool_use", "id": "q-tool"]])))
        try quietBody.write(to: quiet)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: quiet.path)
        let retainTracker = TokenTracker(homeDirectory: retainHome, now: { now }, discoveryInterval: 0)
        check(retainTracker.sample().contains(where: { $0.sessionID == "quiet" }), "Retention fixture: quiet session not discovered")
        for index in 0..<33 {
            var busy = line(claudeUser("b\(index)", "2026-10-04T04:00:02Z", content: "x", extra: ["sessionId": "busy-\(index)"]))
            busy.append(line(["type": "system", "subtype": "stop_hook_summary", "timestamp": "2026-10-04T04:00:03Z"]))
            try busy.write(to: retainFolder.appendingPathComponent("busy-\(index).jsonl"))
        }
        check(retainTracker.sample().contains(where: { $0.sessionID == "quiet" && $0.currentTurnOutputTokens == 10 }),
              "Discovery evicted a quiet session that is still in a turn")

        // A tool result over the 1 MB line limit still completes its call.
        let bigHome = root.appendingPathComponent("oversized")
        let bigFolder = bigHome.appendingPathComponent(".claude/projects/big")
        try FileManager.default.createDirectory(at: bigFolder, withIntermediateDirectories: true)
        var bigBody = line(claudeUser("g-in", "2026-10-04T04:00:00Z", content: "read", extra: ["origin": ["kind": "human"]]))
        bigBody.append(line(claudeReply("g-msg", 10, "2026-10-04T04:00:01Z", "g-out", blocks: [["type": "tool_use", "id": "g-tool"]])))
        bigBody.append(Data("{\"parentUuid\":\"g-out\",\"isSidechain\":false,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"g-tool\",\"type\":\"tool_result\",\"content\":\"".utf8))
        bigBody.append(Data(repeating: 120, count: 1_200_000))
        bigBody.append(Data("\"}]},\"uuid\":\"g-result\",\"timestamp\":\"2026-10-04T04:00:02Z\"}\n".utf8))
        try bigBody.write(to: bigFolder.appendingPathComponent("big.jsonl"))
        let bigReading = TokenTracker(homeDirectory: bigHome, now: { now }, initialTailBytes: 4_194_304).sample().first
        check(bigReading?.activityState == .working, "An oversized tool result left its call running")

        // Readings carry the new fields: input state, tool category, usage limit, context and duration.
        let fieldsHome = root.appendingPathComponent("fields")
        let fieldsClaude = fieldsHome.appendingPathComponent(".claude/projects/fields")
        let fieldsCodex = fieldsHome.appendingPathComponent(".codex/sessions/2026/10/04")
        try FileManager.default.createDirectory(at: fieldsClaude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fieldsCodex, withIntermediateDirectories: true)
        var askBody = line(claudeUser("f-in", "2026-10-04T04:00:00Z", content: "ask",
                                      extra: ["sessionId": "asking", "origin": ["kind": "human"]]))
        askBody.append(line(claudeReply("f-msg", 9, "2026-10-04T04:00:01Z", "f-out",
                                        blocks: [["type": "tool_use", "id": "f-q", "name": "AskUserQuestion"]])))
        try askBody.write(to: fieldsClaude.appendingPathComponent("ask.jsonl"))
        var codexBody = line(["type": "session_meta", "payload": ["id": "fields-codex", "cwd": "/tmp/Fixture/FieldsProject",
                                                                  "timestamp": "2026-10-04T03:59:00Z"]])
        codexBody.append(line(["type": "turn_context", "payload": ["model": "fields-model", "effort": "high"]]))
        codexBody.append(line(codex("task_started", "2026-10-04T03:59:00Z", ["turn_id": "f-1"])))
        codexBody.append(line(limited("2026-10-04T03:59:01Z", used: 42, resets: 1_791_400_000, input: 64_000)))
        codexBody.append(line(codex("task_complete", "2026-10-04T03:59:02Z", ["turn_id": "f-1", "duration_ms": 2_500])))
        codexBody.append(line(codex("task_started", "2026-10-04T04:00:00Z", ["turn_id": "f-2"])))
        codexBody.append(line(["type": "response_item", "timestamp": "2026-10-04T04:00:01Z",
                               "payload": ["type": "custom_tool_call", "call_id": "f-exec", "name": "exec", "input": "PRIVATE_CMD"]]))
        try codexBody.write(to: fieldsCodex.appendingPathComponent("fields.jsonl"))
        let fieldsNow = ISO8601DateFormatter().date(from: "2026-10-04T06:00:00Z")!
        let fields = TokenTracker(homeDirectory: fieldsHome, now: { fieldsNow }).sample()
        let askReading = fields.first(where: { $0.source == .claude })
        check(askReading?.activityState == .input && askReading?.active == true
              && askReading?.toolCategory == .question && askReading?.toolName == "AskUserQuestion",
              "Tracker: a two-hour-old pending question was not reported as live input")
        let codexFields = fields.first(where: { $0.source == .codex })
        check(codexFields?.toolCategory == .command && codexFields?.toolName == "exec"
              && codexFields?.rateLimit?.usedPercent == 42 && codexFields?.context?.usedTokens == 64_000
              && codexFields?.context?.windowTokens == 258_400 && codexFields?.effort == "high"
              && codexFields?.lastTurnDurationSeconds == 2.5 && codexFields?.lastOutputTokens == 10
              && codexFields?.projectPath == "/tmp/Fixture/FieldsProject" && codexFields?.retry == nil,
              "Tracker: Codex tool category, usage limit, context, effort, duration or project path was not exported")
        let encodedFields = String(decoding: (try? JSONEncoder().encode(fields)) ?? Data(), as: UTF8.self)
        check(!encodedFields.contains("PRIVATE") && !encodedFields.contains("turnAverage") && !encodedFields.contains("quality"),
              "Tracker export: tool input, account balance or a log-derived rate field leaked")

        // Resuming an old Codex conversation updates its file, not its date-directory name.
        let resumedHome = root.appendingPathComponent("resumed")
        let currentDay = resumedHome.appendingPathComponent(".codex/sessions/2026/10/04")
        let originalDay = resumedHome.appendingPathComponent(".codex/sessions/2026/09/01")
        try FileManager.default.createDirectory(at: currentDay, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalDay, withIntermediateDirectories: true)
        var olderMeasurement = line(codex("task_started", "2026-10-04T03:00:00Z", ["turn_id": "today"]))
        olderMeasurement.append(line(usage(5, 5, "2026-10-04T03:00:01Z")))
        olderMeasurement.append(line(codex("task_complete", "2026-10-04T03:00:02Z",
            ["turn_id": "today", "duration_ms": 2_000])))
        for index in 0..<32 {
            let url = currentDay.appendingPathComponent("today-\(index).jsonl")
            try olderMeasurement.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: url.path)
        }
        var resumedMeasurement = line(codex("task_started", "2026-10-04T04:00:00Z", ["turn_id": "resumed"]))
        resumedMeasurement.append(line(usage(100, 100, "2026-10-04T04:00:01Z")))
        resumedMeasurement.append(line(codex("task_complete", "2026-10-04T04:00:02Z",
            ["turn_id": "resumed", "duration_ms": 2_000])))
        let resumedFile = originalDay.appendingPathComponent("resumed.jsonl")
        try resumedMeasurement.write(to: resumedFile)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: resumedFile.path)
        let resumedReading = TokenTracker(homeDirectory: resumedHome, now: { now }).sample()[0]
        check(resumedReading.lastTurnDurationSeconds == 2 && resumedReading.lastOutputTokens == 100,
              "Codex discovery omitted a resumed old-date file newer than 32 current-day files")
    } catch {
        checks += 1
        failures.append("Incremental file fixture error: \(error.localizedDescription)")
    }
    print("Tracker checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
