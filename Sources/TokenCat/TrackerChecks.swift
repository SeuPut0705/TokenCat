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
    check(parser.completion?.rate == 50, "Codex: output / completed turn duration")
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
    check(forked.isSubagent && forked.completion?.output == 20 && forked.completion?.rate == 20
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
    check(claude.completion?.rate == 40, "Claude: cache input tokens affected output speed")
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
    check(unknown.completion == nil && unknown.latestOutput == 100, "Claude: missing actual duration must remain unknown")
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
    check(liveCodex.activityState(at: liveStart.addingTimeInterval(126)) == .stale
          && liveCodex.currentTurnStartedAt == liveStart && liveCodex.currentTurnOutputTokens == 100,
          "Codex live: stale logs must keep elapsed time without claiming completion")
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
          && liveClaude.completion?.output == 10 && liveClaude.completion?.rate == 5,
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
        check(first.count == 2 && first.allSatisfy { $0.active && $0.turnAverageTokensPerSecond == nil },
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
              && second.first?.turnAverageTokensPerSecond == nil
              && second.first(where: { $0.sessionID == "session-a" })?.turnAverageTokensPerSecond == 50
              && second.first(where: { $0.sessionID == "session-a" })?.lastOutputTokens == 100,
              "Active session inherited another session's completion, or active-first sorting failed")
        check(Set(first.map(\.id)) == Set(second.map(\.id)), "Incremental updates changed session identity")
        let endingB = line(codex("task_complete", "2026-10-04T04:00:03Z", ["turn_id": "b", "duration_ms": 2_000]))
        let appendB = try FileHandle(forWritingTo: b)
        try appendB.seekToEnd()
        try appendB.write(contentsOf: endingB)
        try appendB.close()
        let third = tracker.sample()[0]
        check(third.turnAverageTokensPerSecond == 10 && third.lastOutputTokens == 20,
              "Incremental completion selected incorrect simultaneous session")
        let repeatSample = tracker.sample()[0]
        check(repeatSample.turnAverageTokensPerSecond == 10, "Repeated file sample duplicated output")
        try Data("{}\n".utf8).write(to: b)
        let truncated = tracker.sample()[0]
        check(truncated.turnAverageTokensPerSecond == 50 && truncated.lastOutputTokens == 100,
              "Truncated file kept stale usage state")

        let modelUpdate = try FileHandle(forWritingTo: a)
        try modelUpdate.seekToEnd()
        try modelUpdate.write(contentsOf: line(["type": "turn_context", "payload": ["model": "model-a-new"]]))
        try modelUpdate.write(contentsOf: line(codex("task_started", "2026-10-04T04:00:03Z", ["turn_id": "a-next"])))
        try modelUpdate.close()
        let switched = tracker.sample().first(where: { $0.sessionID == "session-a" })
        check(switched?.model == "model-a-new" && switched?.measurementModel == "model-a"
              && switched?.turnAverageTokensPerSecond == 50,
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
        let claudeSessions = tracker.sample().filter { $0.source == .claude }
        check(claudeSessions.count == 2 && Set(claudeSessions.map(\.id)).count == 2,
              "Claude main and subagent with the same sessionId were merged or omitted")
        check(claudeSessions.first(where: { $0.isSubagent })?.turnAverageTokensPerSecond == 10
              && claudeSessions.first(where: { !$0.isSubagent })?.turnAverageTokensPerSecond == 30,
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
            $0.isSubagent && $0.agentID == "worker-two" && $0.model == "claude-workflow" && $0.turnAverageTokensPerSecond == 10
        }), "Claude workflow-nested subagent was not discovered or lost its sidechain identity")

        // Begin reading within a large line: suffixes and unseen turn starts cannot produce rates.
        var large = Data(repeating: 32, count: 2_048)
        large.append(10)
        large.append(line(usage(800, 100, "2026-10-04T04:00:04Z")))
        large.append(line(codex("task_complete", "2026-10-04T04:00:05Z", ["turn_id": "unseen", "duration_ms": 1_000])))
        try large.write(to: a)
        let bounded = TokenTracker(homeDirectory: root, now: { now }, initialTailBytes: 256)
        check(bounded.sample().filter { $0.source == .codex }.allSatisfy { $0.turnAverageTokensPerSecond == nil },
              "Initial bounded tail fabricated a turn rate")

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
        check(headerReading?.model == "fresh-tail-model" && headerReading?.turnAverageTokensPerSecond == nil,
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
              && openLong?.active == true && openLong?.turnAverageTokensPerSecond == nil,
              "Starting mid-turn lost current model/activity or fabricated a partial speed")
        check(openLong?.currentTurnStartedAt == ISO8601DateFormatter().date(from: "2026-10-04T04:00:01Z")
              && openLong?.currentTurnOutputTokens == nil && openLong?.activityState == .working
              && openLong?.lastOutputDelta == 50 && openLong?.sampledAt == longNow,
              "Restored live metadata must expose elapsed time and observed delta without inventing a whole-turn output count")
        let longAppend = try FileHandle(forWritingTo: longFile)
        try longAppend.seekToEnd()
        try longAppend.write(contentsOf: line(codex("task_complete", "2026-10-04T04:00:04Z",
            ["turn_id": "long-turn", "duration_ms": 3_000])))
        let closedLong = longTracker.sample().first
        check(closedLong?.active == false && closedLong?.turnAverageTokensPerSecond == nil,
              "A metadata-only open turn stayed active or produced a partial completion")
        check(closedLong?.activityState == .complete && closedLong?.currentTurnStartedAt == nil
              && closedLong?.currentTurnOutputTokens == nil,
              "A restored live turn's completion must close state without a partial-rate accumulator")
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
        check(longTracker.sample().first?.turnAverageTokensPerSecond == 10,
              "The next fully observed turn did not recover normal speed measurement")

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
              && recoveredChild?.turnAverageTokensPerSecond == 20 && recoveredChild?.lastOutputTokens == 20,
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
        check(resumedReading.turnAverageTokensPerSecond == 50 && resumedReading.lastOutputTokens == 100,
              "Codex discovery omitted a resumed old-date file newer than 32 current-day files")
    } catch {
        checks += 1
        failures.append("Incremental file fixture error: \(error.localizedDescription)")
    }
    print("Tracker checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}
