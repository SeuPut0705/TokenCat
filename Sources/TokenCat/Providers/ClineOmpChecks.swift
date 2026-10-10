import Foundation

/// Cline / Roo Code / Cline CLI and omp / Pi fixture files (synthetic metadata, no transcript text): a working turn, a tool,
/// a finished turn, waiting for the person, token totals, model, project, subagents and omp's measured request rate.
/// Run from `runTrackerChecks`.
func runClineOmpChecks(root: URL, check: (Bool, String) -> Void) {
    let start = ISO8601DateFormatter().date(from: "2026-10-04T05:00:00Z")!
    func iso(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: start.addingTimeInterval(seconds))
    }
    func ms(_ seconds: TimeInterval) -> Int64 { Int64((start.addingTimeInterval(seconds).timeIntervalSince1970 * 1_000).rounded()) }
    func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data() }
    func text(_ value: Any) -> String { String(decoding: json(value), as: UTF8.self) }
    func append(_ url: URL, _ records: [[String: Any]]) throws {
        let data = records.reduce(into: Data()) { $0.append(json($1)); $0.append(10) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return try data.write(to: url) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
    var now = start

    do {
        // omp: a main session and a subagent in its session folder.
        let home = root.appendingPathComponent("omp-home")
        let project = home.appendingPathComponent(".omp/agent/sessions/--tmp-Fixture-OmpProject--")
        let stem = "2026-10-04T05-00-00-000Z_omp-main"
        try FileManager.default.createDirectory(at: project.appendingPathComponent(stem), withIntermediateDirectories: true)
        let main = project.appendingPathComponent("\(stem).jsonl")
        func message(_ seconds: TimeInterval, _ body: [String: Any]) -> [String: Any] {
            ["type": "message", "id": UUID().uuidString, "timestamp": iso(seconds), "message": body]
        }
        func assistant(_ seconds: TimeInterval, output: Int, stop: String, tool: (id: String, name: String)? = nil) -> [String: Any] {
            var content: [[String: Any]] = [["type": "text", "text": "PRIVATE_REPLY"]]
            if let tool { content.append(["type": "toolCall", "id": tool.id, "name": tool.name, "arguments": ["command": "PRIVATE_CMD"]]) }
            return message(seconds, ["role": "assistant", "model": "omp-model", "provider": "fixture", "stopReason": stop,
                                     "timestamp": ms(seconds - 2), "completedAt": ms(seconds), "duration": 2_000, "ttft": 500,
                                     "usage": ["input": 10, "output": output, "cacheRead": 9_000, "cacheWrite": 990], "content": content])
        }
        try append(main, [["type": "title", "title": "Omp fixture title"],
                          ["type": "session", "version": 3, "id": "omp-main", "timestamp": iso(0), "cwd": "/tmp/Fixture/OmpProject"],
                          ["type": "model_change", "timestamp": iso(0), "model": "fixture/omp-model"],
                          ["type": "thinking_level_change", "timestamp": iso(0), "thinkingLevel": "high"],
                          message(1, ["role": "user", "content": "PRIVATE_PROMPT", "timestamp": ms(1)]),
                          assistant(4, output: 40, stop: "toolUse", tool: ("call-1", "bash"))])
        now = start.addingTimeInterval(5)
        let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
        var row = tracker.sample().first { !$0.isSubagent }
        check(row?.source == .omp && row?.active == true && row?.activityState == .tool && row?.toolName == "bash"
              && row?.toolCategory == .command && row?.currentTurnOutputTokens == 40 && row?.model == "omp-model"
              && row?.project == "OmpProject" && row?.projectPath == "/tmp/Fixture/OmpProject" && row?.sessionID == "omp-main"
              && row?.effort == "high" && row?.context?.usedTokens == 10_000 && row?.recentOutputs.map(\.tokens) == [40]
              && row?.title == "Omp fixture title",
              "omp: a reply calling a tool was not a running tool turn with its output, model, effort, context, project and title")
        check(row?.speedMeasurement?.outputTokens == 40 && row?.speedMeasurement?.requestDurationMs == 2_000
              && row?.speedMeasurement?.ttftMs == 500 && row?.speedMeasurement?.tokensPerSecond == 20
              && row?.speedMeasurement?.model == "omp-model",
              "omp: the client's own request duration was not reported as a measured request rate")

        try append(main, [message(6, ["role": "toolResult", "toolCallId": "call-1", "toolName": "bash", "content": "PRIVATE_OUT",
                                      "timestamp": ms(6)]),
                          assistant(9, output: 60, stop: "stop")])
        now = start.addingTimeInterval(10)
        row = tracker.sample().first { !$0.isSubagent }
        check(row?.active == false && row?.activityState == .complete && row?.lastOutputTokens == 100
              && row?.currentTurnOutputTokens == nil && row?.recentOutputs.map(\.tokens) == [40, 60],
              "omp: a final reply did not finish the turn with its whole output")

        try append(main, [message(20, ["role": "user", "content": "PRIVATE_PROMPT", "timestamp": ms(20)]),
                          assistant(23, output: 7, stop: "toolUse", tool: ("call-2", "ask"))])
        now = start.addingTimeInterval(7_200)
        row = tracker.sample().first { !$0.isSubagent }
        check(row?.active == true && row?.activityState == .input && row?.toolCategory == .question
              && row?.currentTurnOutputTokens == 7 && row?.lastOutputTokens == 100,
              "omp: a two-hour-old question to the person was not live input")

        let agent = project.appendingPathComponent("\(stem)/Scout.jsonl")
        try append(agent, [["type": "session", "id": "omp-agent", "timestamp": iso(7_190), "cwd": "/tmp/Fixture/OmpProject",
                            "parentSession": main.path],
                           ["type": "session_init", "timestamp": iso(7_190), "agent": "scout", "task": "PRIVATE_TASK"],
                           message(7_191, ["role": "user", "content": "PRIVATE_TASK", "timestamp": ms(7_191)]),
                           assistant(7_195, output: 12, stop: "toolUse", tool: ("call-3", "yield")),
                           message(7_196, ["role": "toolResult", "toolCallId": "call-3", "toolName": "yield", "timestamp": ms(7_196)]),
                           ["type": "custom", "customType": "session_exit", "timestamp": iso(7_196), "data": ["kind": "normal"]]])
        now = start.addingTimeInterval(7_200)
        let sampled = tracker.sample()
        let child = sampled.first { $0.isSubagent }
        check(child?.parentSessionID == "omp-main" && child?.sessionID == "omp-agent" && child?.agentID?.hasSuffix("/Scout") == true
              && child?.agentRole == "scout" && child?.activityState == .complete && child?.active == false
              && child?.lastOutputTokens == 12,
              "omp: a subagent was not grouped under its root session, named, or finished by its exit record")
        let encoded = String(decoding: (try? JSONEncoder().encode(sampled)) ?? Data(), as: UTF8.self)
        check(!encoded.contains("PRIVATE"), "omp: message text or tool arguments leaked into a reading")

        try append(main, [assistant(7_201, output: 3, stop: "aborted")])
        now = start.addingTimeInterval(7_202)
        row = tracker.sample().first { !$0.isSubagent }
        check(row?.active == false && row?.activityState == .interrupted, "omp: an aborted reply did not end the turn as interrupted")

        // A /fork names its parent in `parentSession` but is a top-level conversation; Pi's own folder is labelled Pi.
        let fork = project.appendingPathComponent("2026-10-04T06-00-00-000Z_omp-fork.jsonl")
        try append(fork, [["type": "session", "version": 3, "id": "omp-fork", "timestamp": iso(7_203), "cwd": "/tmp/Fixture/OmpProject",
                           "parentSession": main.path],
                          message(7_203, ["role": "user", "content": "PRIVATE_PROMPT", "timestamp": ms(7_203)]),
                          assistant(7_205, output: 4, stop: "stop")])
        let piProject = home.appendingPathComponent(".pi/agent/sessions/--tmp-Fixture-PiProject--")
        try FileManager.default.createDirectory(at: piProject, withIntermediateDirectories: true)
        try append(piProject.appendingPathComponent("2026-10-04T06-00-00-000Z_pi-main.jsonl"), [
            ["type": "session", "version": 3, "id": "pi-main", "timestamp": iso(7_203), "cwd": "/tmp/Fixture/PiProject"],
            message(7_203, ["role": "user", "content": "PRIVATE_PROMPT", "timestamp": ms(7_203)]),
            assistant(7_205, output: 4, stop: "stop")])
        now = start.addingTimeInterval(7_206)
        let forked = tracker.sample()
        let forkRow = forked.first { $0.sessionID == "omp-fork" }
        check(forkRow?.isSubagent == false && forkRow?.agentID == nil && forkRow?.parentSessionID == nil
              && forkRow?.activityState == .complete,
              "omp: a /fork session with parentSession was folded under its parent as a subagent")
        check(forked.first { $0.sessionID == "pi-main" }?.clientTitle == "Pi" && forkRow?.clientTitle == "omp",
              "omp: a Pi session was not labelled Pi, or an omp session was")

        // omp's own key order (type, ids, timestamp, then the body): tool results and side records are read from their head
        // without decoding the body; a result whose call id follows its content, or an escaped body, still counts.
        let raw = project.appendingPathComponent("2026-10-04T07-00-00-000Z_omp-raw.jsonl")
        func rawLines(_ lines: [String]) throws {
            let data = Data(lines.map { $0 + "\n" }.joined().utf8)
            guard let handle = try? FileHandle(forWritingTo: raw) else { return try data.write(to: raw) }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        try rawLines([
            #"{"type":"session","version":3,"id":"omp-raw","timestamp":"\#(iso(8_000))","cwd":"/tmp/Fixture/OmpProject"}"#,
            #"{"type":"message","id":"r1","parentId":null,"timestamp":"\#(iso(8_001))","message":{"role":"user","content":[{"type":"text","text":"PRIVATE_PROMPT"}],"timestamp":\#(ms(8_001))}}"#,
            #"{"type":"message","id":"r2","parentId":"r1","timestamp":"\#(iso(8_003))","message":{"role":"assistant","content":[{"type":"toolCall","id":"raw-1","name":"bash","arguments":{}},{"type":"toolCall","id":"raw-2","name":"read","arguments":{}}],"model":"omp-model","usage":{"input":1,"output":5},"stopReason":"toolUse","timestamp":\#(ms(8_001))}}"#,
            #"{"type":"message","id":"r3","parentId":"r2","timestamp":"\#(iso(8_004))","message":{"role":"toolResult","toolCallId":"raw-1","toolName":"bash","content":[{"type":"text","text":"PRIVATE_OUT \"timestamp\":\"2030-01-01T00:00:00Z\"}"}],"timestamp":\#(ms(8_004))}}"#,
            #"{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"raw-2","toolName":"read"},"id":"r4","parentId":"r3","timestamp":"\#(iso(8_005))"}"#,
        ])
        now = start.addingTimeInterval(8_031)
        let rawTool = tracker.sample().first { $0.sessionID == "omp-raw" }
        try rawLines([
            #"{"type":"message","id":"r5","parentId":"r4","timestamp":"\#(iso(8_006))","message":{"content":[{"type":"text","text":"PRIVATE_OUT"}],"role":"toolResult","toolCallId":"raw-2","toolName":"read"}}"#,
            #"{"type":"custom_message","customType":"async-result","content":"PRIVATE \"notice\"\n","id":"r6","parentId":"r5","timestamp":"\#(iso(8_030))"}"#,
        ])
        let rawRow = tracker.sample().first { $0.sessionID == "omp-raw" }
        check(rawTool?.activityState == .tool && rawTool?.toolName == "read" && rawTool?.lastLogAt == start.addingTimeInterval(8_005)
              && rawRow?.activityState == .working && rawRow?.toolName == nil && rawRow?.currentTurnOutputTokens == 5
              && rawRow?.lastActivity == start.addingTimeInterval(8_006) && rawRow?.lastLogAt == start.addingTimeInterval(8_030),
              "omp: a tool result or side record read from its head lost its call, time or turn, or one with its call id late was dropped")
    } catch {
        check(false, "omp fixture error: \(error.localizedDescription)")
    }

    do {
        let home = root.appendingPathComponent("omp-account-pins")
        let project = home.appendingPathComponent(".omp/agent/sessions/project")
        let stem = "2026-10-04T05-00-00-000Z_pin-parent"
        let parent = project.appendingPathComponent(stem + ".jsonl")
        let child = project.appendingPathComponent(stem + "/Scout.jsonl")
        let nested = project.appendingPathComponent(stem + "/Scout/Scout.Helper.jsonl")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        let accountA = LimitAccount(id: "shared-workspace", email: "member-a@example.com")
        let accountB = LimitAccount(id: "shared-workspace", email: "member-b@example.com")
        func pin(_ provider: String, _ id: String, _ email: String) -> String {
            LimitAccount.credentialPinHash(provider: provider, accountID: id, email: email, organizationID: nil, projectID: nil)
        }
        let pinA = pin("openai-codex", accountA.id, accountA.email!)
        let pinB = pin("openai-codex", accountB.id, accountB.email!)
        let claudePin = pin("anthropic", "claude-account", "claude@example.com")
        check(try writeLimitCredentialFixture(home.appendingPathComponent(".omp/agent/agent.db"), rows: [
            ("openai-codex", ["accountId": accountA.id, "email": accountA.email!, "access": ["invalid": true]], true),
            ("openai-codex", ["accountId": accountB.id, "email": accountB.email!, "refresh": ["invalid": true]], false),
            ("anthropic", ["accountId": "claude-account", "email": "claude@example.com"], false)]),
            "omp account pins fixture: metadata credentials database could not be created")
        try append(parent, [
            ["type": "session", "id": "pin-parent", "timestamp": iso(0)],
            ["type": "credential_pin", "provider": "openai-codex", "hash": pinB, "timestamp": iso(0)],
            ["type": "credential_pin", "provider": "anthropic", "hash": claudePin, "timestamp": iso(0)],
            ["type": "credential_pin", "provider": "openai-codex", "hash": pinA, "timestamp": iso(1)],
            ["type": "message", "timestamp": iso(2), "message": ["role": "user", "content": String(repeating: "PRIVATE", count: 4_000)]]])
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: parent.path)
        try append(child, [["type": "session", "id": "pin-child", "parentSession": parent.path, "timestamp": iso(2)],
                           ["type": "message", "timestamp": iso(3), "message": ["role": "assistant", "model": "gpt-fixture",
                              "timestamp": ms(3), "usage": ["output": 4], "stopReason": "stop"]]])
        try append(nested, [["type": "session", "id": "pin-nested", "parentSession": child.path, "timestamp": iso(2)],
                            ["type": "message", "timestamp": iso(3), "message": ["role": "assistant", "model": "claude-fixture",
                               "timestamp": ms(3), "usage": ["output": 4], "stopReason": "stop"]]])
        // Newer empty main logs deliberately push the parent beyond the discovery cap.
        for index in 0..<40 { try Data().write(to: project.appendingPathComponent("newer-\(index).jsonl")) }
        now = start.addingTimeInterval(4)
        let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, initialTailBytes: 512, discoveryInterval: 0)
        let rows = tracker.sample()
        let childRow = rows.first { $0.sessionID == "pin-child" }
        let nestedRow = rows.first { $0.sessionID == "pin-nested" }
        check(childRow?.limitAccount == accountA && childRow?.credentialPins[.codex] == pinA
              && nestedRow?.limitAccount?.id == "claude-account" && nestedRow?.credentialPins[.claude] == claudePin,
              "omp account pins: newest provider pin or parent inheritance outside discovery/tail was lost")
        try append(child, [["type": "credential_pin", "provider": "openai-codex", "hash": pinB, "timestamp": iso(4)]])
        let changed = tracker.sample()
        check(changed.first { $0.sessionID == "pin-child" }?.limitAccount == accountB
              && changed.first { $0.sessionID == "pin-nested" }?.credentialPins[.codex] == pinB,
              "omp account pins: a child's newest pin did not override its parent or flow to descendants")
        let encoded = String(decoding: try JSONEncoder().encode(changed), as: UTF8.self)
        check(!encoded.contains("example.com") && !encoded.contains("shared-workspace") && !encoded.contains(pinA)
              && !encoded.contains(pinB) && !encoded.contains(claudePin),
              "omp account pins privacy: inherited credential identity leaked into encoded readings")
    } catch {
        check(false, "omp account pins fixture error: \(error.localizedDescription)")
    }

    do {
        // Cline in VS Code, Roo Code in Cursor, and the Cline CLI.
        let home = root.appendingPathComponent("cline-home")
        let storage = home.appendingPathComponent("Library/Application Support")
        let clineTask = storage.appendingPathComponent("Code/User/globalStorage/saoudrizwan.claude-dev/tasks/1791100000000")
        let rooTask = storage.appendingPathComponent("Cursor/User/globalStorage/rooveterinaryinc.roo-cline/tasks/roo-task")
        let session = home.appendingPathComponent(".cline/data/sessions/cli-1")
        for folder in [clineTask, rooTask, session] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func say(_ seconds: TimeInterval, _ kind: String, _ text: String = "PRIVATE_TEXT", partial: Bool = false,
                 model: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["ts": ms(seconds), "type": "say", "say": kind, "text": text]
            if partial { value["partial"] = true }
            if let model { value["modelInfo"] = ["modelId": model, "providerId": "fixture", "mode": "act"] }
            return value
        }
        func request(_ seconds: TimeInterval, output: Int?, model: String? = "cline-model") -> [String: Any] {
            var info: [String: Any] = ["request": "PRIVATE_REQUEST"]
            if let output { info.merge(["tokensIn": 10, "tokensOut": output, "cacheReads": 0, "cacheWrites": 0, "cost": 0.01]) { $1 } }
            return say(seconds, "api_req_started", text(info), model: model)
        }
        func ask(_ seconds: TimeInterval, _ kind: String) -> [String: Any] { ["ts": ms(seconds), "type": "ask", "ask": kind, "text": "PRIVATE_ASK"] }
        let history = "[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"PRIVATE <environment_details>\\n"
        try Data((history + "# Current Working Directory (/tmp/Fixture/ClineProject) Files\\n</environment_details>\"}]}]").utf8)
            .write(to: clineTask.appendingPathComponent("api_conversation_history.json"))
        let clineLog = clineTask.appendingPathComponent("ui_messages.json")
        try json([say(0, "text"), request(1, output: 30), say(3, "text"), say(4, "tool", text(["tool": "readFile", "path": "PRIVATE_PATH"])),
                  request(5, output: nil)]).write(to: clineLog)
        now = start.addingTimeInterval(6)
        let tracker = TokenTracker(homeDirectory: home, environment: [:], now: { now }, discoveryInterval: 0)
        var rows = tracker.sample()
        var cline = rows.first { $0.sessionID == "1791100000000" }
        check(cline?.source == .cline && cline?.active == true && cline?.activityState == .working && cline?.currentTurnOutputTokens == 30
              && cline?.model == "cline-model" && cline?.project == "ClineProject" && cline?.projectPath == "/tmp/Fixture/ClineProject"
              && cline?.recentOutputs.map(\.tokens) == [30] && cline?.recentOutputs.first?.at == start.addingTimeInterval(4)
              && cline?.speedMeasurement == nil,
              "Cline: an in-flight request was not a working turn with the earlier request's output, model and project")

        try json([say(0, "text"), request(1, output: 30), say(3, "text"), say(4, "tool", text(["tool": "readFile", "path": "PRIVATE_PATH"])),
                  request(5, output: 50), say(8, "completion_result"), ask(8, "completion_result")]).write(to: clineLog)
        now = start.addingTimeInterval(9)
        rows = tracker.sample()
        cline = rows.first { $0.sessionID == "1791100000000" }
        check(cline?.active == false && cline?.activityState == .complete && cline?.lastOutputTokens == 80
              && cline?.currentTurnOutputTokens == nil && cline?.recentOutputs.map(\.tokens) == [30, 50],
              "Cline: a completion did not finish the turn with its whole output")

        try Data((history + "# Current Workspace Directory (/tmp/Fixture/RooProject) Files\\n\\n# Current Mode\\n<model>roo-model</model>"
                  + "\\n</environment_details>\"}]}]").utf8).write(to: rooTask.appendingPathComponent("api_conversation_history.json"))
        try json([say(0, "text"), request(1, output: 20, model: nil), say(3, "text"), ask(4, "followup")])
            .write(to: rooTask.appendingPathComponent("ui_messages.json"))
        now = start.addingTimeInterval(7_200)
        let roo = tracker.sample().first { $0.sessionID == "roo-task" }
        check(roo?.active == true && roo?.activityState == .input && roo?.toolCategory == .question && roo?.model == "roo-model"
              && roo?.project == "RooProject" && roo?.currentTurnOutputTokens == 20,
              "Roo Code: a two-hour-old question was not live input, or its model and workspace were not read")

        // Roo Code orchestration: a subtask ends with `finishTask`, its parent waits on the approved `newTask`.
        let rooTasks = rooTask.deletingLastPathComponent()
        for name in ["roo-sub", "roo-parent"] {
            try FileManager.default.createDirectory(at: rooTasks.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        func toolAsk(_ seconds: TimeInterval, _ tool: String) -> [String: Any] {
            ["ts": ms(seconds), "type": "ask", "ask": "tool", "text": text(["tool": tool, "content": "PRIVATE_TEXT"])]
        }
        try json([say(7_190, "text"), request(7_191, output: 15, model: nil), say(7_192, "completion_result"), toolAsk(7_193, "finishTask")])
            .write(to: rooTasks.appendingPathComponent("roo-sub/ui_messages.json"))
        try json([say(7_180, "text"), request(7_181, output: 5, model: nil), toolAsk(7_182, "newTask")])
            .write(to: rooTasks.appendingPathComponent("roo-parent/ui_messages.json"))
        let orchestrated = tracker.sample()
        let sub = orchestrated.first { $0.sessionID == "roo-sub" }, parent = orchestrated.first { $0.sessionID == "roo-parent" }
        check(sub?.active == false && sub?.activityState == .complete && sub?.lastOutputTokens == 15 && sub?.clientTitle == "Roo Code",
              "Roo Code: a subtask that handed its result back (finishTask) still waited for input, or was not labelled Roo Code")
        check(parent?.active == true && parent?.activityState == .tool && parent?.toolCategory == .agent,
              "Roo Code: a parent waiting on its subtask (newTask) read as a question to the person")

        // A pasted screenshot ahead of the environment details pushes the working directory past 256 KB.
        let bigTask = clineTask.deletingLastPathComponent().appendingPathComponent("1791100000001")
        try FileManager.default.createDirectory(at: bigTask, withIntermediateDirectories: true)
        try Data(("[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"data\":\"" + String(repeating: "A", count: 400_000)
                  + "\"}},{\"type\":\"text\",\"text\":\"<environment_details>\\n# Current Working Directory (/tmp/Fixture/BigProject) Files"
                  + "\\n</environment_details>\"}]}]").utf8).write(to: bigTask.appendingPathComponent("api_conversation_history.json"))
        try json([say(7_190, "text"), request(7_191, output: 10)]).write(to: bigTask.appendingPathComponent("ui_messages.json"))
        check(tracker.sample().first { $0.sessionID == "1791100000001" }?.project == "BigProject",
              "Cline: a working directory after a large pasted image was not found")

        let manifest = session.appendingPathComponent("cli-1.json")
        func writeManifest(_ status: String) throws {
            try json(["version": 1, "session_id": "cli-1", "source": "cli", "pid": 1, "started_at": iso(7_250), "status": status,
                      "interactive": true, "provider": "fixture", "model": "manifest-model", "cwd": "/tmp/Fixture/CliProject",
                      "workspace_root": "/tmp/Fixture/CliProject", "prompt": "PRIVATE_PROMPT"]).write(to: manifest)
        }
        try writeManifest("running")
        let messages = session.appendingPathComponent("cli-1.messages.json")
        try json(["messages": [["role": "user", "content": "PRIVATE_PROMPT", "ts": ms(7_250)],
                               ["role": "assistant", "ts": ms(7_260), "modelInfo": ["id": "cli-model", "provider": "fixture"],
                                "metrics": ["inputTokens": 100, "outputTokens": 25],
                                "content": [["type": "tool_use", "id": "t1", "name": "bash", "input": ["command": "PRIVATE_CMD"]]]]]])
            .write(to: messages)
        now = start.addingTimeInterval(7_270)
        var cli = tracker.sample().first { $0.sessionID == "cli-1" }
        check(cli?.active == true && cli?.activityState == .tool && cli?.toolName == "bash" && cli?.currentTurnOutputTokens == 25
              && cli?.model == "cli-model" && cli?.project == "CliProject",
              "Cline CLI: a running session calling a tool was not a tool turn with its output, model and project")
        try writeManifest("completed")
        cli = tracker.sample().first { $0.sessionID == "cli-1" }
        let encoded = String(decoding: (try? JSONEncoder().encode(tracker.sample())) ?? Data(), as: UTF8.self)
        check(cli?.active == false && cli?.activityState == .complete && cli?.lastOutputTokens == 25 && !encoded.contains("PRIVATE"),
              "Cline CLI: a completed session did not finish its turn, or message text leaked into a reading")
        check(tracker.isLog(clineLog.path) && tracker.isLog(messages.path) && !tracker.isLog(manifest.path)
              && !tracker.isLog(clineTask.appendingPathComponent("api_conversation_history.json").path),
              "Cline: a changed path was matched to the wrong file of a task or session")
    } catch {
        check(false, "Cline fixture error: \(error.localizedDescription)")
    }
}
