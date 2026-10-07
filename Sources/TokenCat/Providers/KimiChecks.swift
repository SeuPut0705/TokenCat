import Foundation

/// Kimi Code, Kimi Work and kimi-cli fixture checks, run inside `runTrackerChecks`. Synthetic metadata only, temp homes; record
/// shapes follow MoonshotAI/kimi-code (agent-core-v2 docs/wire-manifest.d.ts, state-manifest.d.ts, migration-legacy) and the
/// archived MoonshotAI/kimi-cli (wire/types.py, wire/file.py, metadata.py, session_state.py, subagents/store.py).
func kimiChecks(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokencat-kimi-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let start = ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")!
    func ms(_ seconds: TimeInterval) -> Int64 { Int64((start.addingTimeInterval(seconds).timeIntervalSince1970 * 1_000).rounded()) }
    func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
    // Kimi Code serializes `{"type", …payload, "time"}` in that order.
    func wire(_ type: String, _ at: TimeInterval, _ payload: [String: Any] = [:]) -> String {
        let body = payload.isEmpty ? "" : String(json(payload).dropFirst().dropLast()) + ","
        return "{\"type\":\"\(type)\",\(body)\"time\":\(ms(at))}"
    }
    func loop(_ at: TimeInterval, _ event: [String: Any], agent: String = "main") -> String {
        wire("context.append_loop_event", at, ["agentId": agent, "event": event])
    }
    // kimi-cli writes `{"timestamp", "message": {"type", "payload"}}`.
    func legacy(_ type: String, _ at: TimeInterval, _ payload: [String: Any] = [:]) -> String {
        "{\"timestamp\":\(start.addingTimeInterval(at).timeIntervalSince1970),\"message\":{\"type\":\"\(type)\",\"payload\":\(json(payload))}}"
    }
    func write(_ lines: [String], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }
    func write(object: Any, _ url: URL) throws { try write([json(object)], url) }
    func append(_ lines: [String], _ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        try handle.close()
    }
    func encoded(_ readings: [TokenReading]) -> String { String(decoding: (try? JSONEncoder().encode(readings)) ?? Data(), as: UTF8.self) }
    do {
        // Kimi Code: a main agent and one subagent in a session folder, with the session's state.json.
        let home = root.appendingPathComponent("code")
        let session = home.appendingPathComponent(".kimi-code/sessions/wd_kimiproject_0123456789ab/session_kimi-main")
        let mainWire = session.appendingPathComponent("agents/main/wire.jsonl")
        let childWire = session.appendingPathComponent("agents/agent-0/wire.jsonl")
        try write(object: ["id": "session_kimi-main", "version": 1, "cwd": "/tmp/KimiProject", "title": "Kimi fixture title",
                           "titleKind": "generated", "isCustomTitle": false, "lastPrompt": "PRIVATE_PROMPT", "createdAt": ms(0),
                           "updatedAt": ms(1), "archived": false, "custom": [:] as [String: Any],
                           "agents": ["main": ["homedir": "/tmp/h/main", "type": "main"],
                                      "agent-0": ["homedir": "/tmp/h/agent-0", "type": "sub", "parentAgentId": "main",
                                                  "labels": ["profileName": "explore"]]]],
                  session.appendingPathComponent("state.json"))
        func usage(_ at: TimeInterval, output: Int, scope: String = "turn", agent: String = "main") -> String {
            wire("usage.record", at, ["agentId": agent, "model": "kimi-code/k2", "usageScope": scope,
                                      "usage": ["inputOther": 1_000, "output": output, "inputCacheRead": 500, "inputCacheCreation": 0]])
        }
        func request(_ at: TimeInterval, model: String = "kimi-code/kimi-k2-turbo", kind: String = "loop", agent: String = "main") -> String {
            wire("llm.request", at, ["agentId": agent, "kind": kind, "provider": "kimi", "model": model, "modelAlias": "kimi-code/k2",
                                     "thinkingEffort": "high", "toolSelect": false, "systemPromptHash": "h", "systemPrompt": "PRIVATE_SYSTEM",
                                     "toolsHash": "t", "messageCount": 3, "turnStep": "1.1", "attempt": "1"])
        }
        func stepEnd(_ at: TimeInterval, output: Int, reason: String = "tool_use", agent: String = "main") -> String {
            loop(at, ["type": "step.end", "uuid": UUID().uuidString, "turnId": "1", "step": 1, "finishReason": reason,
                      "usage": ["inputOther": 1_000, "output": output, "inputCacheRead": 500, "inputCacheCreation": 0],
                      "llmFirstTokenLatencyMs": 500, "llmStreamDurationMs": 1_500], agent: agent)
        }
        try write([
            "{\"type\":\"metadata\",\"protocol_version\":\"1.5\",\"created_at\":\(ms(0))}",
            wire("profile.bind", 0, ["agentId": "main", "profileName": "coder", "thinkingEffort": "high", "systemPrompt": "PRIVATE_SYSTEM",
                                     "environmentDisclosure": ["cwd": "/tmp/KimiProject"], "disallowedTools": [] as [String]]),
            wire("turn.prompt", 1, ["agentId": "main", "input": [["type": "text", "text": "PRIVATE_PROMPT"]], "origin": "user",
                                    "promptId": "p1", "turnId": 1]),
            wire("context.append_message", 1, ["agentId": "main", "message": ["role": "user", "content": [["type": "text", "text": "PRIVATE_PROMPT"]],
                                                                              "toolCalls": [] as [Any]]]),
            request(2),
            loop(2, ["type": "step.begin", "uuid": "s1", "turnId": "1", "step": 1]),
            loop(3, ["type": "content.part", "stepUuid": "s1", "part": ["type": "think", "think": "PRIVATE_THINKING"]]),
            loop(4, ["type": "tool.call", "stepUuid": "s1", "toolCallId": "call_1", "name": "Bash", "args": ["command": "PRIVATE_COMMAND"],
                     "uuid": "u1", "turnId": "1", "step": 1]),
            stepEnd(4, output: 40),
            usage(4, output: 40),
        ], mainWire)
        try write([
            "{\"type\":\"metadata\",\"protocol_version\":\"1.5\",\"created_at\":\(ms(5))}",
            wire("turn.prompt", 5, ["agentId": "agent-0", "input": [["type": "text", "text": "PRIVATE_TASK"]], "origin": "task", "turnId": 1]),
            request(6, model: "kimi-k2-sub", agent: "agent-0"),
            usage(7, output: 12, agent: "agent-0"),
            wire("turn.ended", 8, ["agentId": "agent-0", "turnId": 1, "reason": "completed", "durationMs": 3_000]),
        ], childWire)
        var now = start.addingTimeInterval(5)
        let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
        var rows = tracker.sample()
        var row = rows.first { !$0.isSubagent }
        check(row?.source == .kimi && row?.active == true && row?.activityState == .tool && row?.toolName == "Bash"
              && row?.toolCategory == .command && row?.currentTurnOutputTokens == 40 && row?.currentTurnStartedAt == start.addingTimeInterval(1)
              && row?.model == "kimi-k2-turbo" && row?.effort == "high" && row?.project == "KimiProject"
              && row?.projectPath == "/tmp/KimiProject" && row?.sessionID == "session_kimi-main" && row?.title == "Kimi fixture title"
              && row?.context?.usedTokens == 1_500 && row?.clientName == nil,
              "Kimi Code: an open turn running a tool read cold lost its tool, turn output, model, effort, context, project or generated title")
        check(row?.speedMeasurement?.outputTokens == 40 && row?.speedMeasurement?.requestDurationMs == 2_000
              && row?.speedMeasurement?.ttftMs == 500 && row?.speedMeasurement?.tokensPerSecond == 20
              && row?.speedMeasurement?.model == "kimi-k2-turbo",
              "Kimi Code: a step's own first-token and streaming time was not reported as a measured request rate")
        let child = rows.first { $0.isSubagent }
        check(child?.parentSessionID == "session_kimi-main" && child?.sessionID == "session_kimi-main" && child?.agentID == "agent-0"
              && child?.agentRole == "explore" && child?.activityState == .complete && child?.active == false
              && child?.lastOutputTokens == 12 && child?.model == "kimi-k2-sub" && child?.title == nil && child?.project == "KimiProject",
              "Kimi Code: a subagent was not grouped under its session, named by its profile, or finished with its own output and model")

        // The tool result arrives (sorted keys: a writer that does not put `type` first is still read), then an approval wait.
        try append([
            json(["type": "context.append_loop_event", "agentId": "main", "time": ms(10),
                  "event": ["type": "tool.result", "toolCallId": "call_1", "parentUuid": "u1", "result": ["output": "PRIVATE_OUTPUT"]]]),
            loop(11, ["type": "tool.call", "stepUuid": "s2", "toolCallId": "call_2", "name": "Bash", "args": ["command": "PRIVATE"]]),
            wire("interaction.request", 11, ["agentId": "main", "id": "int_1", "kind": "approval", "toolCallId": "call_2",
                                             "request": ["command": "PRIVATE_COMMAND"]]),
        ], mainWire)
        now = start.addingTimeInterval(7_200)
        row = tracker.sample().first { !$0.isSubagent }
        check(row?.activityState == .input && row?.active == true && row?.toolName == "Bash" && row?.currentTurnOutputTokens == 40,
              "Kimi Code: a two-hour-old approval request was not live input")
        try append([
            wire("interaction.resolved", 7_201, ["agentId": "main", "id": "int_1", "response": ["decision": "PRIVATE"]]),
            loop(7_202, ["type": "tool.result", "parentUuid": "u2", "toolCallId": "call_2", "result": ["output": "PRIVATE_OUTPUT"]]),
            request(7_203),
            stepEnd(7_205, output: 60, reason: "end_turn"),
            usage(7_205, output: 60),
            wire("turn.ended", 7_206, ["agentId": "main", "turnId": 1, "reason": "completed", "durationMs": 9_000, "stopReason": "end_turn"]),
            wire("prompt.completed", 7_206, ["agentId": "main", "promptId": "p1", "finishedAt": "2026-10-04T14:00:06Z", "reason": "completed"]),
        ], mainWire)
        now = start.addingTimeInterval(7_207)
        row = tracker.sample().first { !$0.isSubagent }
        check(row?.active == false && row?.activityState == .complete && row?.lastOutputTokens == 100 && row?.lastTurnDurationSeconds == 9
              && row?.currentTurnOutputTokens == nil && row?.toolName == nil && row?.recentOutputs.map(\.tokens) == [60]
              && row?.speedMeasurement?.outputTokens == 60,
              "Kimi Code: turn.ended did not finish the turn with its whole output and the client's own duration")

        // Compaction between turns neither opens a turn nor counts as turn output.
        try append([request(7_300, model: "compaction-model", kind: "compaction"), usage(7_301, output: 900, scope: "session")], mainWire)
        now = start.addingTimeInterval(7_302)
        row = tracker.sample().first { !$0.isSubagent }
        check(row?.activityState == .complete && row?.model == "kimi-k2-turbo" && row?.lastOutputTokens == 100
              && row?.recentOutputs.map(\.tokens) == [60],
              "Kimi Code: a compaction request or session-scoped usage reopened the turn, changed the model or counted as output")
        try append([wire("turn.prompt", 7_400, ["agentId": "main", "input": [["type": "text", "text": "PRIVATE"]], "origin": "user", "turnId": 2])],
                   mainWire)
        now = start.addingTimeInterval(7_401)
        row = tracker.sample().first { !$0.isSubagent }
        check(row?.activityState == .working && row?.active == true && row?.currentTurnOutputTokens == 0
              && row?.currentTurnStartedAt == start.addingTimeInterval(7_400) && row?.lastOutputTokens == 100,
              "Kimi Code: a new prompt did not start a counted turn at zero")
        try append([wire("turn.ended", 7_410, ["agentId": "main", "turnId": 2, "reason": "cancelled", "durationMs": 10_000])], mainWire)
        now = start.addingTimeInterval(7_411)
        rows = tracker.sample()
        row = rows.first { !$0.isSubagent }
        check(row?.activityState == .interrupted && row?.active == false && row?.lastOutputTokens == 100,
              "Kimi Code: a cancelled turn did not end as interrupted")
        check(!encoded(rows).contains("PRIVATE"), "Kimi Code: transcript text leaked into a reading")

        // Titles: only generated or user-set ones; never the prompt copy, never an imported kimi-cli fallback.
        check(KimiLog.title(["title": "Fix login", "titleKind": "custom"]) == "Fix login"
              && KimiLog.title(["title": "PRIVATE_PROMPT", "titleKind": "replaceable"]) == nil
              && KimiLog.title(["title": "PRIVATE_PROMPT", "isCustomTitle": false]) == nil
              && KimiLog.title(["title": "Renamed", "isCustomTitle": true]) == "Renamed"
              && KimiLog.title(["title": "PRIVATE_PROMPT", "titleKind": "generated", "custom": ["imported_from_kimi_cli": true]]) == nil
              && KimiLog.modelName("kimi-code/kimi-for-coding") == "kimi-for-coding" && KimiLog.modelName("__kimi_env_model__") == nil,
              "Kimi Code: a prompt-copy or imported title was shown, a generated or renamed one was not, or a model id was misread")

        // KIMI_CODE_HOME moves the store; Kimi Work's embedded runtime is labelled as such.
        let custom = home.appendingPathComponent("custom-kimi")
        let workSession = home.appendingPathComponent(
            "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions/wd_work_0123456789ab/conv-work")
        for (folder, cwd) in [(custom.appendingPathComponent("sessions/wd_moved_0123456789ab/session_moved"), "/tmp/KimiMoved"),
                              (workSession, "/tmp/KimiWork")] {
            try write(object: ["id": folder.lastPathComponent, "cwd": cwd, "title": "PRIVATE_PROMPT", "titleKind": "replaceable"],
                      folder.appendingPathComponent("state.json"))
            try write([wire("turn.prompt", 7_405, ["agentId": "main", "input": [] as [Any], "origin": "user"])],
                      folder.appendingPathComponent("agents/main/wire.jsonl"))
        }
        let moved = TokenTracker(homeDirectory: home, environment: ["KIMI_CODE_HOME": custom.path], now: { now }, discoveryInterval: 0).sample()
        check(moved.contains { $0.sessionID == "session_moved" && $0.project == "KimiMoved" && $0.title == nil }
              && !moved.contains { $0.sessionID == "session_kimi-main" }
              && moved.first { $0.sessionID == "conv-work" }?.clientName == "Kimi Work",
              "Kimi Code: KIMI_CODE_HOME was not followed, or a Kimi Work session was not labelled Kimi Work")
    } catch {
        check(false, "Kimi Code fixtures could not be written: \(error)")
    }

    do {
        // kimi-cli: `sessions/<md5(work dir)>/<session>/wire.jsonl`, a subagent beside it, kimi.json and config.toml.
        let home = root.appendingPathComponent("cli")
        let share = home.appendingPathComponent(".kimi")
        let group = share.appendingPathComponent("sessions/\(KimiLog.workDirFolder("/tmp/KimiLegacy", kaos: "local"))")
        let session = group.appendingPathComponent("legacy-session")
        let mainWire = session.appendingPathComponent("wire.jsonl")
        try write(object: ["work_dirs": [["path": "/tmp/Elsewhere", "kaos": "local"],
                                         ["path": "/tmp/KimiLegacy", "kaos": "local", "last_session_id": "legacy-session"]]],
                  share.appendingPathComponent("kimi.json"))
        try write(["default_model = \"k2\" # fixture", "", "[models.\"k2\"]", "provider = \"kimi\"", "model = \"kimi-k2-0905-preview\"",
                   "max_context_size = 262144", "", "[models.other]", "model = \"other-model\""], share.appendingPathComponent("config.toml"))
        func status(_ at: TimeInterval, output: Int, id: String) -> String {
            legacy("StatusUpdate", at, ["token_usage": ["input_other": 100, "output": output, "input_cache_read": 0, "input_cache_creation": 0],
                                        "message_id": id, "context_tokens": 5_000, "max_context_tokens": 262_144, "context_usage": 0.02,
                                        "plan_mode": false])
        }
        try write([
            "{\"type\":\"metadata\",\"protocol_version\":\"1.3\"}",
            legacy("TurnBegin", 1, ["user_input": "PRIVATE_PROMPT"]),
            legacy("StepBegin", 2, ["n": 1]),
            legacy("ContentPart", 3, ["type": "text", "text": "PRIVATE_REPLY"]),
            legacy("ToolCall", 4, ["type": "function", "id": "tc1", "function": ["name": "Shell", "arguments": "PRIVATE_ARGS"]]),
            legacy("ToolCallPart", 4, ["arguments_part": "PRIVATE"]),
            status(4, output: 30, id: "m1"),
        ], mainWire)
        let agent = session.appendingPathComponent("subagents/a1234567")
        try write(object: ["agent_id": "a1234567", "subagent_type": "coder", "status": "completed", "description": "PRIVATE_DESCRIPTION",
                           "created_at": 1.0, "updated_at": 2.0,
                           "launch_spec": ["agent_id": "a1234567", "subagent_type": "coder", "effective_model": "kimi-k2-sub", "created_at": 1.0]],
                  agent.appendingPathComponent("meta.json"))
        try write([legacy("TurnBegin", 5, ["user_input": "PRIVATE_TASK"]), status(6, output: 7, id: "s1"), legacy("TurnEnd", 7)],
                  agent.appendingPathComponent("wire.jsonl"))
        // A session Kimi Code's migration already copied: written before the marker, so the Kimi Code copy is the one shown.
        let migrated = group.appendingPathComponent("migrated-session/wire.jsonl")
        try write([legacy("TurnBegin", -90_000), legacy("TurnEnd", -89_000)], migrated)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: migrated.path)
        try write([], share.appendingPathComponent(".migrated-to-kimi-code"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)],
                                              ofItemAtPath: share.appendingPathComponent(".migrated-to-kimi-code").path)

        var now = start.addingTimeInterval(5)
        let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
        var rows = tracker.sample()
        var row = rows.first { !$0.isSubagent }
        check(row?.source == .kimi && row?.clientName == "Kimi CLI" && row?.activityState == .tool && row?.toolName == "Shell"
              && row?.active == true && row?.currentTurnOutputTokens == 30 && row?.model == "kimi-k2-0905-preview"
              && row?.project == "KimiLegacy" && row?.sessionID == "legacy-session" && row?.context?.usedTokens == 5_000
              && row?.context?.windowTokens == 262_144 && row?.title == nil && row?.speedMeasurement == nil,
              "kimi-cli: an open tool turn read cold lost its tool, output, configured model, project from kimi.json or context window")
        let child = rows.first { $0.isSubagent }
        check(child?.parentSessionID == "legacy-session" && child?.agentID == "a1234567" && child?.agentRole == "coder"
              && child?.model == "kimi-k2-sub" && child?.activityState == .complete && child?.lastOutputTokens == 7,
              "kimi-cli: a subagent was not grouped under its session with its meta.json type and model")
        check(!rows.contains { $0.sessionID == "migrated-session" },
              "kimi-cli: a session already migrated to Kimi Code was listed twice")
        try append([legacy("ToolResult", 6, ["tool_call_id": "tc1", "return_value": ["output": "PRIVATE_OUTPUT", "is_error": false]]),
                     status(6, output: 30, id: "m1"),
                     legacy("ToolCall", 7, ["type": "function", "id": "tc2", "function": ["name": "Shell", "arguments": "PRIVATE"]]),
                     legacy("ApprovalRequest", 7, ["id": "ap1", "tool_call_id": "tc2", "sender": "Shell", "action": "PRIVATE",
                                                   "description": "PRIVATE_DESCRIPTION"])], mainWire)
        now = start.addingTimeInterval(3_600)
        row = tracker.sample().first { !$0.isSubagent }
        check(row?.activityState == .input && row?.active == true && row?.currentTurnOutputTokens == 30,
              "kimi-cli: an approval request was not live input, or a repeated StatusUpdate was counted twice")
        // The next step's response reuses the id "m1", as some OpenAI-compatible gateways do for every response.
        try append([legacy("ApprovalResponse", 3_601, ["request_id": "ap1", "response": "approve", "feedback": ""]),
                     legacy("ToolResult", 3_602, ["tool_call_id": "tc2", "return_value": ["output": "PRIVATE"]]),
                     legacy("StepBegin", 3_602, ["n": 2]), status(3_603, output: 20, id: "m1"), legacy("TurnEnd", 3_604)], mainWire)
        now = start.addingTimeInterval(3_605)
        rows = tracker.sample()
        row = rows.first { !$0.isSubagent }
        check(row?.activityState == .complete && row?.active == false && row?.lastOutputTokens == 50
              && row?.recentOutputs.map(\.tokens) == [20],
              "kimi-cli: TurnEnd did not finish the turn with its whole output, or a later step reusing a response id was dropped")
        check(!encoded(rows).contains("PRIVATE"), "kimi-cli: transcript text leaked into a reading")
        check(KimiLog.configuredModel(toml: "default_model = 'a'\n[models.a]\nmodel = \"kimi-code/m\"\n") == "m"
              && KimiLog.configuredModel(toml: "default_model = \"missing\"\n[models.a]\nmodel = \"x\"\n") == nil
              && KimiLog.configuredModel(json: ["default_model": "a", "models": ["a": ["model": "json-model"]]]) == "json-model"
              && KimiLog.workDirFolder("/tmp/KimiLegacy", kaos: "ssh").hasPrefix("ssh_"),
              "kimi-cli: the configured model or a remote work directory's folder name was misread")
    } catch {
        check(false, "kimi-cli fixtures could not be written: \(error)")
    }
}
