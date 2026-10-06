import Foundation

/// Copilot CLI, Amp and Droid fixture checks, run inside `runTrackerChecks`. Synthetic metadata only, temp homes.
func copilotAmpDroidChecks(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokencat-copilot-amp-droid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
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
    func write(_ data: Data, _ url: URL, modified: TimeInterval? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(modified)], ofItemAtPath: url.path)
        }
    }
    func append(_ data: Data, _ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
    do {
        // Copilot CLI
        func event(_ type: String, _ at: TimeInterval, _ data: [String: Any] = [:], agent: String? = nil) -> [String: Any] {
            var record: [String: Any] = ["type": type, "id": UUID().uuidString, "timestamp": stamp(at), "data": data]
            if let agent { record["agentId"] = agent }
            return record
        }
        let copilotHome = root.appendingPathComponent("copilot")
        let state = copilotHome.appendingPathComponent(".copilot/session-state")
        try write(lines([
            event("session.start", 0, ["sessionId": "copilot-working", "selectedModel": "claude-sonnet-4.5",
                                        "context": ["cwd": "/tmp/CopilotProject"], "reasoningEffort": "high"]),
            event("user.message", 1, ["content": "PRIVATE_PROMPT"]),
            event("assistant.turn_start", 2, ["turnId": "0"]),
            event("assistant.message", 3, ["messageId": "m1", "content": "PRIVATE_REPLY", "model": "gpt-5", "outputTokens": 40,
                                            "toolRequests": [["toolCallId": "c1", "name": "bash", "arguments": ["command": "PRIVATE"]]]]),
            event("tool.execution_start", 4, ["toolCallId": "c1", "toolName": "bash"]),
            event("assistant.message", 5, ["messageId": "s1", "content": "", "model": "sub-model", "outputTokens": 5], agent: "sub-1"),
        ]), state.appendingPathComponent("copilot-working/events.jsonl"))
        try write(Data("id: copilot-done\ncwd: \"/tmp/YamlProject\"\nsummary: 'Copilot''s fixture\tsummary'\nsummary_count: 0\n".utf8),
                  state.appendingPathComponent("copilot-done/workspace.yaml"))
        try write(lines([
            event("user.message", 1, ["content": "PRIVATE"]),
            event("assistant.turn_start", 2, ["turnId": "0"]),
            event("assistant.message", 3, ["messageId": "d1", "content": "", "model": "gpt-5", "outputTokens": 30,
                                            "toolRequests": [["toolCallId": "d-c1", "name": "view"]]]),
            event("tool.execution_start", 4, ["toolCallId": "d-c1", "toolName": "view"]),
            event("tool.execution_complete", 5, ["toolCallId": "d-c1", "success": true]),
            event("assistant.turn_end", 6, ["turnId": "0"]),
            event("assistant.turn_start", 7, ["turnId": "1"]),
            event("assistant.message", 8, ["messageId": "d2", "content": "PRIVATE", "model": "gpt-5", "outputTokens": 20]),
            event("assistant.turn_end", 9, ["turnId": "1"]),
        ]), state.appendingPathComponent("copilot-done/events.jsonl"))
        try write(lines([
            event("user.message", 1, ["content": "PRIVATE"]),
            event("assistant.message", 2, ["messageId": "p1", "content": "", "outputTokens": 10,
                                            "toolRequests": [["toolCallId": "p-c1", "name": "bash"]]]),
            event("permission.requested", 3, ["requestId": "perm-1", "permissionRequest": ["kind": "shell"]]),
        ]), state.appendingPathComponent("copilot-permission/events.jsonl"))
        try write(lines([
            event("user.message", 1, ["content": "PRIVATE"]),
            event("assistant.turn_start", 2, ["turnId": "0"]),
        ]), state.appendingPathComponent("copilot-crashed/events.jsonl"))
        try write(Data("2147483\n".utf8), state.appendingPathComponent("copilot-crashed/inuse.2147483.lock"))
        var copilotNow = start.addingTimeInterval(10)
        let copilotTracker = TokenTracker(homeDirectory: copilotHome, environment: [:], now: { copilotNow })
        let copilot = copilotTracker.sample()
        let working = copilot.first { $0.sessionID == "copilot-working" }
        check(working?.source == .copilot && working?.active == true && working?.activityState == .tool
              && working?.toolName == "bash" && working?.toolCategory == .other,
              "Copilot CLI: a running tool after the person's message was not shown as a live tool turn")
        check(working?.currentTurnOutputTokens == 45 && working?.currentTurnStartedAt == start.addingTimeInterval(1)
              && working?.recentOutputs.map(\.tokens) == [40, 5] && working?.model == "gpt-5" && working?.effort == "high",
              "Copilot CLI: outputTokens (subagent output included) or the main model were not counted for the open turn")
        check(working?.project == "CopilotProject" && working?.projectPath == "/tmp/CopilotProject",
              "Copilot CLI: session.start context.cwd was not kept as the project")
        let done = copilot.first { $0.sessionID == "copilot-done" }
        check(done?.active == false && done?.activityState == .complete && done?.lastOutputTokens == 50
              && done?.lastTurnDurationSeconds == nil && done?.speedMeasurement == nil,
              "Copilot CLI: a turn_end after a reply without tool requests must complete the turn with its whole output, no speed")
        check(done?.project == "YamlProject" && done?.projectPath == "/tmp/YamlProject" && done?.title == "Copilot's fixture summary",
              "Copilot CLI: workspace.yaml cwd was not used when the log has no session.start, or its generated summary is no title")
        let asking = copilot.first { $0.sessionID == "copilot-permission" }
        copilotNow = start.addingTimeInterval(1_200)
        let later = copilotTracker.sample()
        check(asking?.activityState == .input && later.first { $0.sessionID == "copilot-permission" }?.activityState == .input
              && later.first { $0.sessionID == "copilot-working" }?.activityState == .stale,
              "Copilot CLI: a pending permission request must wait for the person while a silent tool turn goes stale")
        let crashed = copilot.first { $0.sessionID == "copilot-crashed" }
        check(crashed?.active == false && crashed?.activityState == .unfinished,
              "Copilot CLI: an open turn whose inuse lock names an exited process stayed live")
        let encoded = String(decoding: (try? JSONEncoder().encode(copilot)) ?? Data(), as: UTF8.self)
        check(!encoded.contains("PRIVATE") && working?.title == nil,
              "Copilot CLI: prompt, reply or tool input text leaked, or a session without workspace.yaml got a title")
        // A rename writes `name:` (and the same `summary:`); the yaml is read again although the event log did not change.
        try write(Data("id: copilot-done\ncwd: \"/tmp/YamlProject\"\nsummary: \"Renamed \\\"fixture\\\" #1\"\nname: \"Renamed \\\"fixture\\\" #1\"\n".utf8),
                  state.appendingPathComponent("copilot-done/workspace.yaml"))
        check(copilotTracker.sample().first { $0.sessionID == "copilot-done" }?.title == "Renamed \"fixture\" #1"
              && CopilotLogReader.yamlValues("name: |-\n  Block\n  title\nsummary: plain: text\n", keys: ["name", "summary"])
                == ["name": "Block\ntitle", "summary": "plain: text"],
              "Copilot CLI: a renamed workspace.yaml did not update the title, or a quoted, block or plain scalar was misread")

        // Amp
        let ampHome = root.appendingPathComponent("amp")
        let threads = ampHome.appendingPathComponent(".local/share/amp/threads")
        func thread(_ id: String, _ messages: [[String: Any]], ledger: [[String: Any]] = [], title: String = "Amp fixture title") -> Data {
            (try? JSONSerialization.data(withJSONObject: [
                "v": 3, "id": id, "created": Int(start.timeIntervalSince1970 * 1_000), "title": title,
                "env": ["initial": ["trees": [["displayName": "AmpProject", "uri": "file:///tmp/AmpProject"]]]],
                "messages": messages, "usageLedger": ["events": ledger],
            ])) ?? Data()
        }
        func ampUser(_ id: Int, _ at: TimeInterval, _ content: [[String: Any]]) -> [String: Any] {
            ["role": "user", "messageId": id, "content": content, "meta": ["sentAt": Int(start.addingTimeInterval(at).timeIntervalSince1970 * 1_000)]]
        }
        func ampReply(_ id: Int, _ at: TimeInterval?, tokens: Int?, stop: String, tools: [String] = []) -> [String: Any] {
            var message: [String: Any] = ["role": "assistant", "messageId": id, "state": ["type": "complete", "stopReason": stop],
                "content": [["type": "text", "text": "PRIVATE"]] + tools.map { ["type": "tool_use", "id": $0, "name": "Bash", "input": ["cmd": "PRIVATE"]] }]
            if let at, let tokens { message["usage"] = ["model": "claude-sonnet-4", "outputTokens": tokens, "inputTokens": 900, "timestamp": stamp(at)] }
            return message
        }
        let prompt: [[String: Any]] = [["type": "text", "text": "PRIVATE_PROMPT"]]
        func result(_ id: String, _ status: String) -> [[String: Any]] { [["type": "tool_result", "toolUseID": id, "run": ["status": status]]] }
        try write(thread("T-working", [ampUser(0, 1, prompt), ampReply(1, 2, tokens: 60, stop: "tool_use", tools: ["a-t1"]),
                                       ampUser(2, 3, result("a-t1", "in-progress"))]),
                  threads.appendingPathComponent("T-working.json"), modified: 5)
        try write(thread("T-done", [ampUser(0, 1, prompt), ampReply(1, 2, tokens: 70, stop: "tool_use", tools: ["d-t1"]),
                                    ampUser(2, 3, result("d-t1", "done")), ampReply(3, nil, tokens: nil, stop: "end_turn")],
                         ledger: [["timestamp": stamp(4), "model": "claude-sonnet-4", "toMessageId": 3, "tokens": ["input": 10, "output": 15]]]),
                  threads.appendingPathComponent("T-done.json"), modified: 4)
        try write(thread("T-blocked", [ampUser(0, 1, prompt), ampReply(1, 2, tokens: 8, stop: "tool_use", tools: ["b-t1"]),
                                       ampUser(2, 3, result("b-t1", "blocked-on-user"))]),
                  threads.appendingPathComponent("T-blocked.json"), modified: 3)
        let amp = TokenTracker(homeDirectory: ampHome, environment: [:], now: { start.addingTimeInterval(10) }).sample()
        let ampWorking = amp.first { $0.sessionID == "T-working" }
        check(ampWorking?.active == true && ampWorking?.activityState == .tool && ampWorking?.toolName == "Bash"
              && ampWorking?.currentTurnOutputTokens == 60 && ampWorking?.currentTurnStartedAt == start.addingTimeInterval(1)
              && ampWorking?.model == "claude-sonnet-4",
              "Amp: a tool still running after a tool_use reply was not a live tool turn with its output and model")
        check(ampWorking?.project == "AmpProject" && ampWorking?.projectPath == "/tmp/AmpProject",
              "Amp: env.initial.trees file URL was not kept as the project")
        let ampDone = amp.first { $0.sessionID == "T-done" }
        check(ampDone?.active == false && ampDone?.activityState == .complete && ampDone?.lastOutputTokens == 85
              && ampDone?.recentOutputs.map(\.tokens) == [70, 15],
              "Amp: an end_turn reply must complete the turn, counting usageLedger output for a message without usage")
        check(amp.first { $0.sessionID == "T-blocked" }?.activityState == .input,
              "Amp: a tool blocked on the person must wait for input")
        let ampEncoded = String(decoding: (try? JSONEncoder().encode(amp)) ?? Data(), as: UTF8.self)
        check(amp.count == 3 && !ampEncoded.contains("PRIVATE") && ampDone?.title == "Amp fixture title",
              "Amp: thread text leaked, a thread was missed, or its title was not kept")
        try write(thread("T-done", [ampUser(0, 1, prompt), ampReply(1, 2, tokens: 70, stop: "end_turn")], title: "Amp renamed thread"),
                  threads.appendingPathComponent("T-done.json"), modified: 6)
        check(TokenTracker(homeDirectory: ampHome, environment: [:], now: { start.addingTimeInterval(10) }).sample()
                .first { $0.sessionID == "T-done" }?.title == "Amp renamed thread",
              "Amp: a renamed thread snapshot did not update the title")

        // Droid
        let droidHome = root.appendingPathComponent("droid")
        let droidFolder = droidHome.appendingPathComponent(".factory/sessions/-tmp-DroidProject")
        let droidLog = droidFolder.appendingPathComponent("droid-session.jsonl")
        let droidSettings = droidFolder.appendingPathComponent("droid-session.settings.json")
        func droidMessage(_ role: String, _ at: TimeInterval, _ content: [[String: Any]], visibility: String? = nil) -> [String: Any] {
            var message: [String: Any] = ["role": role, "content": content]
            if let visibility { message["visibility"] = visibility }
            return ["type": "message", "id": UUID().uuidString, "timestamp": stamp(at), "message": message]
        }
        func settings(_ output: Int, modified: TimeInterval) throws {
            try write((try? JSONSerialization.data(withJSONObject: [
                "model": "custom:qwen3:30b-[Ollama]-0", "reasoningEffort": "high",
                "tokenUsage": ["inputTokens": 5_000, "outputTokens": output, "thinkingTokens": 0],
            ])) ?? Data(), droidSettings, modified: modified)
        }
        try write(lines([
            ["type": "session_start", "id": "droid-session", "title": "PRIVATE_TITLE", "cwd": "/tmp/DroidProject", "version": 2],
            droidMessage("user", 0, [["type": "text", "text": "PRIVATE_CONTEXT"]], visibility: "llm_only"),
            droidMessage("user", 0.1, [["type": "text", "text": "PRIVATE_PROMPT"]]),
            droidMessage("assistant", 1, [["type": "thinking", "thinking": "PRIVATE"],
                                          ["type": "tool_use", "id": "dr-t1", "name": "Execute", "input": ["command": "PRIVATE"]]]),
        ]), droidLog)
        try settings(100, modified: 1)
        var droidNow = start.addingTimeInterval(2)
        let droidTracker = TokenTracker(homeDirectory: droidHome, environment: [:], now: { droidNow })
        let droidOpen = droidTracker.sample().first
        check(droidOpen?.source == .droid && droidOpen?.active == true && droidOpen?.activityState == .tool
              && droidOpen?.toolName == "Execute" && droidOpen?.currentTurnOutputTokens == nil
              && droidOpen?.model == "qwen3:30b" && droidOpen?.effort == "high" && droidOpen?.project == "DroidProject",
              "Droid: an open tool turn read cold lost its model or project, or counted output from before its known total")
        try append(lines([droidMessage("user", 3, [["type": "tool_result", "tool_use_id": "dr-t1", "content": "PRIVATE"]]),
                          droidMessage("assistant", 4, [["type": "text", "text": "PRIVATE"]])]), droidLog)
        droidNow = start.addingTimeInterval(5)
        let droidClosed = droidTracker.sample().first
        check(droidClosed?.active == false && droidClosed?.activityState == .complete && droidClosed?.lastOutputTokens == nil,
              "Droid: a text reply after the tool result must complete the turn without inventing its output")
        try append(lines([droidMessage("user", 20, [["type": "text", "text": "PRIVATE_PROMPT"]])]), droidLog)
        droidNow = start.addingTimeInterval(21)
        let droidNext = droidTracker.sample().first
        check(droidNext?.activityState == .working && droidNext?.currentTurnOutputTokens == 0
              && droidNext?.currentTurnStartedAt == start.addingTimeInterval(20),
              "Droid: a new prompt after a known total must start a counted turn at zero")
        try settings(160, modified: 25)
        try append(lines([droidMessage("assistant", 26, [["type": "text", "text": "PRIVATE"]])]), droidLog)
        droidNow = start.addingTimeInterval(27)
        let droidDone = droidTracker.sample().first
        check(droidDone?.activityState == .complete && droidDone?.lastOutputTokens == 60
              && droidDone?.recentOutputs.last?.tokens == 60 && droidDone?.recentOutputs.last?.at == start.addingTimeInterval(25),
              "Droid: growth of the settings output total was not logged at its write time and credited to the turn")
        let droidEncoded = String(decoding: (try? JSONEncoder().encode(droidDone)) ?? Data(), as: UTF8.self)
        check(!droidEncoded.contains("PRIVATE") && droidDone?.title == nil && DroidLogReader.modelName("claude-opus-4-1") == "claude-opus-4-1",
              "Droid: transcript text or the first-message title leaked, or a plain model name was rewritten")
        // Droid rewrites its first line with a generated title, then with a rename that keeps the file's times.
        let droidBody = try Data(contentsOf: droidLog)
        func retitle(_ header: [String: Any]) throws {
            let rest = droidBody[droidBody.firstIndex(of: 10).map { droidBody.index(after: $0) }!...]
            var data = lines([header])
            data.append(rest)
            let times = try FileManager.default.attributesOfItem(atPath: droidLog.path)[.modificationDate]
            try data.write(to: droidLog)
            if let times { try FileManager.default.setAttributes([.modificationDate: times], ofItemAtPath: droidLog.path) }
        }
        let header: [String: Any] = ["type": "session_start", "id": "droid-session", "cwd": "/tmp/DroidProject", "version": 2]
        try retitle(header.merging(["title": "Droid fixture title", "sessionTitleAutoStage": "first_message",
                                    "isSessionTitleManuallySet": false]) { $1 })
        droidNow = start.addingTimeInterval(30)
        let generated = TokenTracker(homeDirectory: droidHome, environment: [:], now: { droidNow }).sample().first?.title
        try retitle(header.merging(["title": "Droid renamed", "isSessionTitleManuallySet": true]) { $1 })
        check(generated == "Droid fixture title" && droidTracker.sample().first?.title == "Droid renamed",
              "Droid: a generated or renamed session_start title was not shown, or the in-place rename was missed")
    } catch {
        check(false, "Copilot/Amp/Droid fixtures could not be written: \(error)")
    }
}
