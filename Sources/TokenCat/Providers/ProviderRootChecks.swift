import Foundation

/// Data folders and environment overrides of clients read by an existing format, and the products that write one of those
/// formats into their own folders (`TokenClientRoots`). Temp homes with environment dictionaries, synthetic metadata only.
/// Run inside `runTrackerChecks`.
func providerRootChecks(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokencat-provider-roots-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let start = ISO8601DateFormatter().date(from: "2026-10-04T04:00:00Z")!
    let now = start.addingTimeInterval(10)
    func iso(_ seconds: TimeInterval) -> String { ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)) }
    func ms(_ seconds: TimeInterval) -> Int64 { Int64(start.addingTimeInterval(seconds).timeIntervalSince1970 * 1_000) }
    func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data() }
    func write(_ url: URL, _ records: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try records.reduce(into: Data()) { $0.append(json($1)); $0.append(10) }.write(to: url)
    }
    func encoded(_ rows: [TokenReading]) -> String { String(decoding: (try? JSONEncoder().encode(rows)) ?? Data(), as: UTF8.self) }
    /// A Codex rollout in a running turn: an exec call after a usage-limit snapshot.
    func rollout(_ url: URL, _ session: String) throws {
        func event(_ type: String, _ at: TimeInterval, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["type": "event_msg", "timestamp": iso(at), "payload": extra.merging(["type": type]) { $1 }]
        }
        try write(url, [
            ["type": "session_meta", "timestamp": iso(0), "payload": ["id": session, "cwd": "/tmp/Fixture/RolloutProject", "timestamp": iso(0)]],
            ["type": "turn_context", "timestamp": iso(0), "payload": ["model": "gpt-fixture", "effort": "high"]],
            event("task_started", 1, ["turn_id": "t1"]),
            event("token_count", 2, ["info": ["total_token_usage": ["output_tokens": 10], "last_token_usage": ["output_tokens": 10, "input_tokens": 500],
                                              "model_context_window": 258_400],
                                     "rate_limits": ["limit_id": "codex", "primary": ["used_percent": 42, "window_minutes": 10_080, "resets_at": 1_791_400_000]]]),
            ["type": "response_item", "timestamp": iso(3),
             "payload": ["type": "custom_tool_call", "call_id": "c1", "name": "exec", "input": "PRIVATE_CMD"]],
        ])
    }
    /// A Claude Code transcript whose reply is running a Bash call.
    func transcript(_ url: URL, _ session: String) throws {
        try write(url, [
            ["type": "user", "uuid": "\(session)-in", "timestamp": iso(1), "sessionId": session, "cwd": "/tmp/Fixture/ClaudeProject",
             "origin": ["kind": "human"], "message": ["role": "user", "content": "PRIVATE_PROMPT"]],
            ["type": "assistant", "uuid": "\(session)-out", "timestamp": iso(2), "sessionId": session, "cwd": "/tmp/Fixture/ClaudeProject",
             "message": ["id": "\(session)-msg", "model": "claude-fixture", "usage": ["output_tokens": 30],
                         "content": [["type": "tool_use", "id": "\(session)-tool", "name": "Bash", "input": ["command": "PRIVATE_CMD"]]]]],
        ])
    }
    func running(_ row: TokenReading?, tool: String) -> Bool {
        row?.active == true && row?.activityState == .tool && row?.toolName == tool
    }

    do {
        // Codex: CODEX_HOME, with ~/.codex kept; TRAE CLI (a codex-rs fork) in ~/.trae/cli/sessions and TRAEX_SESSIONS_DIR.
        let home = root.appendingPathComponent("codex-home")
        let codexHome = root.appendingPathComponent("elsewhere/codex")
        let traeDir = root.appendingPathComponent("elsewhere/traex")
        try rollout(codexHome.appendingPathComponent("sessions/2026/10/04/moved.jsonl"), "codex-moved")
        try rollout(home.appendingPathComponent(".codex/sessions/2026/10/04/default.jsonl"), "codex-default")
        try rollout(home.appendingPathComponent(".trae/cli/sessions/2026/10/04/trae.jsonl"), "trae-default")
        try rollout(traeDir.appendingPathComponent("2026/10/04/trae.jsonl"), "trae-moved")
        let rows = TokenTracker(homeDirectory: home, environment: ["CODEX_HOME": codexHome.path, "TRAEX_SESSIONS_DIR": traeDir.path],
                                now: { now }).sample()
        func row(_ id: String) -> TokenReading? { rows.first { $0.sessionID == id } }
        check(running(row("codex-moved"), tool: "exec") && row("codex-moved")?.clientName == nil && row("codex-moved")?.rateLimit?.usedPercent == 42
              && row("codex-moved")?.model == "gpt-fixture" && row("codex-moved")?.project == "RolloutProject"
              && running(row("codex-default"), tool: "exec"),
              "Codex: a rollout under CODEX_HOME or the ~/.codex fallback was not read as a running tool turn")
        let trae = [row("trae-default"), row("trae-moved")]
        check(trae.allSatisfy { running($0, tool: "exec") && $0?.source == .codex && $0?.clientTitle == "TRAE CLI" && $0?.rateLimit == nil
                  && $0?.currentTurnOutputTokens == 10 && $0.map(SessionPresentation.resumeCommand) == .some(nil) }
              && row("codex-default").map(SessionPresentation.resumeCommand) != .some(nil) && !encoded(rows).contains("PRIVATE"),
              "TRAE CLI: a Codex-format rollout under ~/.trae/cli/sessions or TRAEX_SESSIONS_DIR was not read and labelled TRAE CLI, or kept Codex's usage limit or resume command")
    } catch {
        check(false, "Codex roots fixture error: \(error.localizedDescription)")
    }

    do {
        // Claude Code: CLAUDE_CONFIG_DIR (a comma list), $XDG_CONFIG_HOME/claude and ~/.claude; set-aside transcripts are skipped.
        let home = root.appendingPathComponent("claude-home")
        let work = root.appendingPathComponent("elsewhere/claude-work"), team = root.appendingPathComponent("elsewhere/claude-team")
        let xdg = root.appendingPathComponent("elsewhere/xdg")
        try transcript(work.appendingPathComponent("projects/-tmp-a/work.jsonl"), "claude-work")
        try transcript(team.appendingPathComponent("projects/-tmp-a/team.jsonl"), "claude-team")
        try transcript(xdg.appendingPathComponent("claude/projects/-tmp-a/xdg.jsonl"), "claude-xdg")
        let project = home.appendingPathComponent(".claude/projects/-tmp-a")
        try transcript(project.appendingPathComponent("default.jsonl"), "claude-default")
        let orphan = project.appendingPathComponent("default.orphaned-1791100000000-x1.jsonl")
        try transcript(orphan, "claude-orphan")
        // OpenClaude in ~/.openclaude and OPENCLAUDE_CONFIG_DIR; Qoder in ~/.qoder and flat in its IDE's SharedClientCache.
        let openClaude = root.appendingPathComponent("elsewhere/openclaude")
        try transcript(home.appendingPathComponent(".openclaude/projects/-tmp-a/oc.jsonl"), "openclaude-default")
        try transcript(openClaude.appendingPathComponent("projects/-tmp-a/oc.jsonl"), "openclaude-moved")
        try transcript(home.appendingPathComponent(".qoder/projects/-tmp-a/q.jsonl"), "qoder-cli")
        try transcript(home.appendingPathComponent("Library/Application Support/Qoder/SharedClientCache/cli/projects/q.jsonl"), "qoder-ide")
        let tracker = TokenTracker(homeDirectory: home, environment: [
            "CLAUDE_CONFIG_DIR": "\(work.path), \(team.path)", "XDG_CONFIG_HOME": xdg.path, "OPENCLAUDE_CONFIG_DIR": openClaude.path,
        ], now: { now })
        let rows = tracker.sample()
        func row(_ id: String) -> TokenReading? { rows.first { $0.sessionID == id } }
        check(["claude-work", "claude-team", "claude-xdg", "claude-default"].allSatisfy {
                  running(row($0), tool: "Bash") && row($0)?.clientName == nil && row($0)?.currentTurnOutputTokens == 30
                      && row($0)?.model == "claude-fixture" && row($0)?.project == "ClaudeProject" },
              "Claude Code: CLAUDE_CONFIG_DIR (a comma list), $XDG_CONFIG_HOME/claude or ~/.claude projects were not all read")
        check(row("claude-orphan") == nil && !tracker.isLog(orphan.path) && tracker.isLog(project.appendingPathComponent("default.jsonl").path),
              "Claude Code: a set-aside .orphaned- transcript was listed or taken as a log")
        let clones = ["openclaude-default": "OpenClaude", "openclaude-moved": "OpenClaude", "qoder-cli": "Qoder", "qoder-ide": "Qoder"]
        check(clones.allSatisfy { id, name in
                  running(row(id), tool: "Bash") && row(id)?.source == .claude && row(id)?.clientTitle == name
                      && row(id)?.currentTurnOutputTokens == 30 && row(id)?.project == "ClaudeProject"
                      && row(id).map(SessionPresentation.resumeCommand) == .some(nil) }
              && row("claude-default").map(SessionPresentation.resumeCommand) != .some(nil) && !encoded(rows).contains("PRIVATE"),
              "OpenClaude/Qoder: a Claude-format transcript in their folders was not read and labelled, or offered Claude Code's resume command")
    } catch {
        check(false, "Claude roots fixture error: \(error.localizedDescription)")
    }

    do {
        // Gemini CLI under the macOS Seatbelt sandbox; Factory Droid with FACTORY_HOME_OVERRIDE.
        let home = root.appendingPathComponent("sandbox-home")
        let geminiChat = home.appendingPathComponent(".cache/.gemini/tmp/repo/chats/session-1.jsonl")
        try write(geminiChat, [["sessionId": "gem", "startTime": iso(0)]])
        let factory = root.appendingPathComponent("elsewhere/factory")
        let droidLog = factory.appendingPathComponent(".factory/sessions/-tmp-a/droid.jsonl")
        try write(droidLog, [["type": "session_start", "id": "droid"]])
        let tracker = TokenTracker(homeDirectory: home, environment: ["FACTORY_HOME_OVERRIDE": factory.path], now: { now })
        let detected = tracker.detectedSources()
        check(detected.contains(.gemini) && tracker.isLog(geminiChat.path),
              "Gemini CLI: the Seatbelt sandbox folder ~/.cache/.gemini/tmp was not detected or its chats not taken as logs")
        check(detected.contains(.droid) && tracker.isLog(droidLog.path),
              "Droid: sessions under FACTORY_HOME_OVERRIDE were not detected or taken as logs")
    } catch {
        check(false, "Gemini/Droid roots fixture error: \(error.localizedDescription)")
    }

    do {
        // Cline's shared task store (~/.cline/data/tasks, CLINE_DATA_DIR) and Cline-format extensions in any editor folder.
        let home = root.appendingPathComponent("cline-home")
        let data = root.appendingPathComponent("elsewhere/cline-data")
        let support = home.appendingPathComponent("Library/Application Support")
        func say(_ seconds: TimeInterval, _ kind: String, _ text: String = "PRIVATE_TEXT") -> [String: Any] {
            ["ts": ms(seconds), "type": "say", "say": kind, "text": text]
        }
        let request = say(2, "api_req_started", String(decoding: json(["request": "PRIVATE_REQUEST", "tokensIn": 10, "tokensOut": 25]), as: UTF8.self))
        let tool = say(3, "tool", String(decoding: json(["tool": "readFile", "path": "PRIVATE_PATH"]), as: UTF8.self))
        func task(_ folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try json([say(1, "text"), request, tool, say(4, "api_req_started", "{}")]).write(to: folder.appendingPathComponent("ui_messages.json"))
        }
        try task(home.appendingPathComponent(".cline/data/tasks/shared-task"))
        try task(data.appendingPathComponent("tasks/moved-task"))
        try task(support.appendingPathComponent("Antigravity/User/globalStorage/zoocodeorganization.zoo-code/tasks/zoo-task"))
        try task(support.appendingPathComponent("IBM Bob/User/globalStorage/ibm.bob-code/tasks/bob-task"))
        try task(support.appendingPathComponent("Kiro/User/globalStorage/saoudrizwan.claude-dev/tasks/kiro-task"))
        let sessions = root.appendingPathComponent("elsewhere/cline-sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let tracker = TokenTracker(homeDirectory: home, environment: ["CLINE_DATA_DIR": data.path, "CLINE_SESSION_DATA_DIR": sessions.path],
                                   now: { now })
        let rows = tracker.sample()
        func row(_ id: String) -> TokenReading? { rows.first { $0.sessionID == id } }
        let names: [String: String] = ["shared-task": "Cline", "moved-task": "Cline", "kiro-task": "Cline", "zoo-task": "Zoo Code", "bob-task": "IBM Bob"]
        check(names.allSatisfy { id, name in row(id)?.source == .cline && row(id)?.active == true && row(id)?.clientTitle == name
                  && row(id)?.currentTurnOutputTokens == 25 }
              && TokenProvider.all.first { $0.source == .cline }?.existingRoots(home: home, environment: ["CLINE_SESSION_DATA_DIR": sessions.path])
                  .contains { $0.path == sessions.path } == true
              && !encoded(rows).contains("PRIVATE"),
              "Cline: a task in ~/.cline/data/tasks, CLINE_DATA_DIR, CLINE_SESSION_DATA_DIR or another editor's Zoo Code/IBM Bob/Cline folder was not read or labelled")
    } catch {
        check(false, "Cline roots fixture error: \(error.localizedDescription)")
    }

    do {
        // omp: named profiles, PI_CONFIG_DIR, $XDG_DATA_HOME/omp (and its profiles); Pi: PI_CODING_AGENT_SESSION_DIR.
        let home = root.appendingPathComponent("omp-home")
        let xdg = root.appendingPathComponent("elsewhere/xdg-data")
        let piSessions = root.appendingPathComponent("elsewhere/pi-sessions")
        func session(_ folder: URL, _ id: String) throws {
            try write(folder.appendingPathComponent("--tmp-Fixture-OmpProject--/2026-10-04T04-00-00-000Z_\(id).jsonl"), [
                ["type": "session", "version": 3, "id": id, "timestamp": iso(0), "cwd": "/tmp/Fixture/OmpProject"],
                ["type": "message", "id": "\(id)-u", "timestamp": iso(1), "message": ["role": "user", "content": "PRIVATE_PROMPT", "timestamp": ms(1)]],
                ["type": "message", "id": "\(id)-a", "timestamp": iso(3), "message": [
                    "role": "assistant", "model": "omp-model", "provider": "fixture", "stopReason": "toolUse", "timestamp": ms(2),
                    "usage": ["input": 10, "output": 40], "content": [["type": "toolCall", "id": "\(id)-c", "name": "bash", "arguments": ["command": "PRIVATE_CMD"]]]]],
            ])
        }
        try session(home.appendingPathComponent(".omp/profiles/work/agent/sessions"), "omp-profile")
        try session(home.appendingPathComponent(".ompx/agent/sessions"), "omp-config")
        try session(home.appendingPathComponent(".ompx/profiles/team/agent/sessions"), "omp-config-profile")
        try session(xdg.appendingPathComponent("omp/sessions"), "omp-xdg")
        try session(xdg.appendingPathComponent("omp/profiles/work/sessions"), "omp-xdg-profile")
        try session(piSessions, "pi-moved")
        let rows = TokenTracker(homeDirectory: home, environment: [
            "PI_CONFIG_DIR": ".ompx", "XDG_DATA_HOME": xdg.path, "PI_CODING_AGENT_SESSION_DIR": piSessions.path,
        ], now: { now }).sample()
        func row(_ id: String) -> TokenReading? { rows.first { $0.sessionID == id } }
        check(["omp-profile", "omp-config", "omp-config-profile", "omp-xdg", "omp-xdg-profile"].allSatisfy {
                  running(row($0), tool: "bash") && row($0)?.clientTitle == "omp" && row($0)?.currentTurnOutputTokens == 40 }
              && running(row("pi-moved"), tool: "bash") && row("pi-moved")?.clientTitle == "Pi" && !encoded(rows).contains("PRIVATE"),
              "omp/Pi: a session in a named profile, PI_CONFIG_DIR, $XDG_DATA_HOME/omp or PI_CODING_AGENT_SESSION_DIR was not read or was mislabelled")
    } catch {
        check(false, "omp roots fixture error: \(error.localizedDescription)")
    }
}
