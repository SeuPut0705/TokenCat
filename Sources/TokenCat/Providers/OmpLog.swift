import Foundation

/// omp and Pi coding-agent sessions: `<root>/<encoded cwd>/<timestamp>_<id>.jsonl`, with subagent sessions nested in the
/// session's folder (`<timestamp>_<id>/<Agent>.jsonl`, then `<Agent>/<Agent.Child>.jsonl`). Append-only JSONL read through
/// `LogLineTail`. Only the session header, model and thinking level, message roles, usage counts, the client's own request
/// timing (`duration`, `ttft`), stop reasons and tool names survive; message content is never kept.
extension TokenLogFormat {
    static let omp = TokenLogFormat(files: { roots, discovery in
        var main: [URL] = []
        var subagents: [URL] = []
        func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == false }
        func nested(_ folder: URL, depth: Int) {
            for entry in discovery.children(folder) {
                if entry.pathExtension == "jsonl" { subagents.append(entry) }
                else if depth > 0, isFolder(entry) { nested(entry, depth: depth - 1) }
            }
        }
        for project in roots.flatMap(discovery.children) {
            for entry in discovery.children(project) {
                if entry.pathExtension == "jsonl" { main.append(entry) }
                else if isFolder(entry) { nested(entry, depth: 2) }
            }
        }
        // Subagents come in bursts; they get their own cap so main sessions stay visible.
        return discovery.recent(main) + discovery.recent(subagents, keepingSince: discovery.now.addingTimeInterval(-3_600))
    }, isLog: { $0.hasSuffix(".jsonl") }, open: { OmpLogReader(url: $0) })
}

private final class OmpLogReader: TokenLogReader {
    private let url: URL
    private let tail: LogLineTail
    private var state: OmpLogState
    private var headerRead = false

    init(url: URL) {
        self.url = url
        tail = LogLineTail(url: url)
        state = OmpLogState(url: url)
    }

    func read(tailLimit: Int, now: Date) {
        tail.read(tailLimit: tailLimit, reset: { [url] in
            state = OmpLogState(url: url)
            headerRead = false
        }, line: { state.consume($0, headSkipped: tail.skippedHead) })
        // The header (a title line, then the session line) is lost when the first read starts mid-file.
        guard tail.skippedHead, !headerRead, let handle = try? FileHandle(forReadingFrom: url) else { return }
        headerRead = true
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 65_536) else { return }
        for line in head.split(separator: 10).prefix(8) { state.consumeHeader(Data(line)) }
    }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard let lastActivity = state.lastActivity else { return [] }
        var reading = TokenReading(source: .omp, id: id)
        reading.sessionID = state.sessionID
        reading.parentSessionID = state.parentSessionID
        reading.agentID = state.agentID
        reading.isSubagent = state.isSubagent
        reading.agentRole = state.agentRole
        reading.project = state.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        reading.projectPath = state.cwd
        reading.model = state.model
        reading.effort = state.effort
        reading.context = state.context
        reading.lastActivity = lastActivity
        reading.lastLogAt = state.lastLogAt
        reading.measurementAt = state.completion?.at ?? lastActivity
        reading.active = state.isActive(at: now)
        reading.activityState = state.activityState(at: now)
        if let tool = state.runningTool {
            reading.toolName = tool
            reading.toolCategory = OmpLogState.category(tool)
        }
        reading.currentTurnStartedAt = state.open ? state.turnStartedAt : nil
        reading.currentTurnOutputTokens = state.open && state.turnStartedAt != nil ? state.turnOutput : nil
        reading.lastOutputAt = state.events.last?.at
        reading.lastOutputDelta = state.events.last?.tokens
        reading.recentOutputs = state.events.filter {
            let age = now.timeIntervalSince($0.at)
            return age >= -5 && age <= TokenTracker.recentOutputWindow
        }
        reading.speedMeasurement = state.measurement
        reading.lastOutputTokens = state.completion?.output
        reading.sampledAt = now
        return [reading]
    }

    func isRecent(at now: Date) -> Bool {
        state.open || [state.lastLogAt, state.lastActivity].compactMap { $0 }.max().map { now.timeIntervalSince($0) <= 3_600 } == true
    }
}

/// Turn state of one omp or Pi session log.
private struct OmpLogState {
    private(set) var sessionID: String?
    private(set) var parentSessionID: String?
    private(set) var agentID: String?
    private(set) var isSubagent: Bool
    private(set) var agentRole: String?
    private(set) var cwd: String?
    private(set) var model: String?
    private(set) var effort: String?
    private(set) var context: TokenContextUsage?
    private(set) var lastActivity: Date?
    private(set) var lastLogAt: Date?
    private(set) var open = false
    private(set) var turnStartedAt: Date?
    private(set) var turnOutput = 0
    private(set) var completion: (output: Int, at: Date)?
    private(set) var events: [TokenOutputEvent] = []
    private(set) var measurement: TokenSpeedMeasurement?
    private var observed: TokenActivityState = .idle
    private var sawContent = false
    /// Outstanding tool calls in call order, id → name. Arguments are never read.
    private var pendingTools: [(id: String, name: String)] = []

    /// A subagent lives in its root session's folder (`<timestamp>_<root id>/…`); that id groups it under the root. The agent
    /// id keeps a slash so the row is titled by the agent's own name (the file name, e.g. `Scout` or `Scout.Helper`).
    init(url: URL) {
        let rootID = url.deletingLastPathComponent().pathComponents.reversed().lazy.compactMap(Self.sessionFileID).first
        isSubagent = rootID != nil
        parentSessionID = rootID
        agentID = rootID.map { "\($0)/\(url.deletingPathExtension().lastPathComponent)" }
    }

    /// The id in a session file or folder name such as `2026-10-06T07-17-38-289Z_<id>`.
    private static func sessionFileID(_ name: String) -> String? {
        guard name.count > 25, name.prefix(4).allSatisfy(\.isNumber), name.dropFirst(10).first == "T",
              let separator = name.firstIndex(of: "_") else { return nil }
        let id = name[name.index(after: separator)...]
        return id.isEmpty ? nil : String(id)
    }

    /// Identity records only, for a header the tail skipped: never usage, turns or times.
    mutating func consumeHeader(_ line: Data) {
        guard let record = LogFields.object(line) else { return }
        consumeIdentity(record)
    }

    mutating func consume(_ line: Data, headSkipped: Bool) {
        guard let record = LogFields.object(line) else { return }
        let at = LogFields.date(record["timestamp"])
        if let at { lastLogAt = max(lastLogAt ?? at, at) }
        consumeIdentity(record)
        switch record["type"] as? String {
        case "model_change":
            // "provider/model"; assistant messages name the model alone.
            if model == nil, let value = LogFields.text(record["model"]) {
                model = value.split(separator: "/", maxSplits: 1).last.map(String.init)
            }
        case "thinking_level_change": effort = TokenLogParser.label(record["thinkingLevel"]) ?? effort
        case "message":
            guard let message = record["message"] as? [String: Any] else { return }
            consumeMessage(message, at: at ?? LogFields.milliseconds(message["timestamp"]), headSkipped: headSkipped)
        case "custom" where record["customType"] as? String == "session_exit":
            guard open else { return }
            open = false
            let normal = (record["data"] as? [String: Any])?["kind"] as? String == "normal"
            observed = normal ? .complete : .interrupted
            if normal, let at, turnStartedAt != nil { completion = (turnOutput, at) }
            pendingTools.removeAll()
        default: return
        }
    }

    private mutating func consumeIdentity(_ record: [String: Any]) {
        switch record["type"] as? String {
        case "session":
            sessionID = LogFields.text(record["id"]) ?? sessionID
            if let path = LogFields.text(record["cwd"]), path.count <= 4_096 { cwd = path }
            if let parent = LogFields.text(record["parentSession"]) {
                isSubagent = true
                if parentSessionID == nil {
                    parentSessionID = Self.sessionFileID(URL(fileURLWithPath: parent).deletingPathExtension().lastPathComponent)
                }
                if agentID == nil { agentID = sessionID }
            }
        case "session_init": agentRole = TokenLogParser.label(record["agent"]) ?? agentRole
        default: return
        }
    }

    private mutating func consumeMessage(_ message: [String: Any], at: Date?, headSkipped: Bool) {
        guard let at else { return }
        let role = message["role"] as? String
        guard role == "user" || role == "assistant" || role == "toolResult" else { return }
        // A tail that starts inside a turn has not seen its prompt, so that turn's output is unknown.
        let unseenStart = headSkipped && !sawContent
        sawContent = true
        switch role {
        case "user":
            lastActivity = max(lastActivity ?? at, at)
            // A steering message joins the running turn.
            if !open { openTurn(at) }
            observed = .working
        case "assistant":
            let finished = LogFields.milliseconds(message["completedAt"]) ?? at
            lastActivity = max(lastActivity ?? finished, finished)
            if !open { openTurn(unseenStart ? nil : LogFields.milliseconds(message["timestamp"]) ?? at) }
            if let name = LogFields.text(message["model"]), name.count <= 128 { model = name }
            let usage = message["usage"] as? [String: Any]
            let output = LogFields.count(usage?["output"]) ?? 0
            if output > 0 {
                turnOutput += output
                events.append(TokenOutputEvent(at: finished, tokens: output))
                if events.count > 512 { events.removeFirst(events.count - 512) }
            }
            let used = ["input", "cacheRead", "cacheWrite"].compactMap { LogFields.count(usage?[$0]) }.reduce(0, +)
            if used > 0 { context = TokenContextUsage(usedTokens: used, windowTokens: nil, recordedAt: finished) }
            let stop = message["stopReason"] as? String
            // The client's own timing of this request (start to completion, first token included); never log times.
            if output > 0, stop != "aborted", stop != "error", let duration = Self.milliseconds(message["duration"]), duration > 0 {
                var speed = TokenSpeedMeasurement(TelemetryReading(provider: .omp, at: finished))
                speed.model = model
                speed.outputTokens = output
                speed.requestDurationMs = duration
                speed.ttftMs = Self.milliseconds(message["ttft"])
                measurement = speed
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "toolCall" {
                guard let id = LogFields.text(block["id"]) else { continue }
                pendingTools.removeAll { $0.id == id }
                pendingTools.append((id, TokenLogParser.label(block["name"]) ?? "tool"))
                if pendingTools.count > 256 { pendingTools.removeFirst(pendingTools.count - 256) }
            }
            switch stop {
            case "stop", "length":
                if turnStartedAt != nil { completion = (turnOutput, finished) }
                closeTurn(.complete)
            case "aborted", "error": closeTurn(.interrupted)
            default: observed = pendingTools.isEmpty ? .working : .tool
            }
        default:
            lastActivity = max(lastActivity ?? at, at)
            if !open { openTurn(unseenStart ? nil : at) }
            if let id = LogFields.text(message["toolCallId"]) { pendingTools.removeAll { $0.id == id } }
            observed = pendingTools.isEmpty ? .working : .tool
        }
    }

    private mutating func openTurn(_ start: Date?) {
        open = true
        turnStartedAt = start
        turnOutput = 0
        pendingTools.removeAll()
    }

    private mutating func closeTurn(_ state: TokenActivityState) {
        open = false
        observed = state
        pendingTools.removeAll()
    }

    private static func milliseconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 && result <= 604_800_000 ? result : nil
    }

    /// omp's `ask` tool waits for the person.
    private var waitsForInput: Bool { open && pendingTools.contains { $0.name == "ask" } }

    var runningTool: String? {
        guard open else { return nil }
        return (pendingTools.last { $0.name == "ask" } ?? pendingTools.last)?.name
    }

    /// How long an open turn may stay silent and still count as running. Subagent tools (`task`, `wait`) block for as
    /// long as their agents run; a question waits for the person.
    private var liveHorizon: TimeInterval {
        if waitsForInput { return 86_400 }
        guard let tool = pendingTools.last?.name else { return 600 }
        return Self.category(tool) == .agent ? 3_600 : 900
    }

    private var liveAt: Date? { [lastLogAt, lastActivity].compactMap { $0 }.max() }

    func isActive(at now: Date) -> Bool {
        guard open, let liveAt else { return false }
        let age = now.timeIntervalSince(liveAt)
        return age >= -5 && age <= liveHorizon
    }

    func activityState(at now: Date) -> TokenActivityState {
        guard open else { return observed }
        if waitsForInput { return isActive(at: now) ? .input : .unfinished }
        if isActive(at: now) { return observed }
        guard let liveAt, now.timeIntervalSince(liveAt) <= 1_800 else { return .unfinished }
        return .stale
    }

    /// omp and Pi name their tools in lower case.
    static func category(_ name: String) -> ToolCategory {
        if name.hasPrefix("mcp_") { return .mcp }
        switch name {
        case "bash", "eval", "python", "shell", "exec": return .command
        case "read", "write", "edit", "glob", "grep", "find", "ls", "ast_edit", "ast_grep", "notebook": return .file
        case "web_search", "web_fetch", "fetch", "browser": return .web
        case "task", "wait", "yield", "agent": return .agent
        case "ask": return .question
        default: return TokenLogParser.category(name)
        }
    }
}
