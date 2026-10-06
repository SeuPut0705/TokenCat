import Foundation

/// Cline, Roo Code and Kilo Code tasks in a VS Code family editor (`globalStorage/<extension>/tasks/<task>/ui_messages.json`)
/// and Cline CLI sessions (`~/.cline/data/sessions/<id>/<id>.messages.json` beside its `<id>.json` manifest).
/// Both are JSON snapshots rewritten in place: a changed modification time or size rereads the file. Only ask/say kinds,
/// token counts, times, model ids and the working directory survive; message text is never kept.
extension TokenLogFormat {
    static let cline = TokenLogFormat(files: { roots, discovery in
        var found: [URL] = []
        for root in roots {
            let extensionTasks = root.lastPathComponent == "tasks"
            for folder in discovery.children(root) {
                let name = extensionTasks ? "ui_messages.json" : "\(folder.lastPathComponent).messages.json"
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { found.append(url) }
            }
        }
        return discovery.recent(found)
    }, isLog: { path in
        let name = (path as NSString).lastPathComponent
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return name == "ui_messages.json" || name == folder + ".messages.json"
    }, open: { ClineLogReader(url: $0) })
}

/// One task or CLI session. The whole snapshot is summarised on every change; nothing but the summary is kept.
private final class ClineLogReader: TokenLogReader {
    private let url: URL
    private let cli: Bool
    /// Roo Code and Kilo Code, by the extension folder the task lives in; nil for Cline.
    private let clientName: String?
    private var stamp: ClineLogStamp?
    private var parsedAt: Date?
    private var summary: ClineLogSummary?
    private var cwd: String?
    /// The first request was read without a working directory in it: it is never searched again.
    private var cwdSearched = false
    /// Extension tasks: the newest model named in the conversation's environment details (Roo Code, Kilo Code).
    private var historyModel: String?
    private var historyStamp: ClineLogStamp?
    private var manifestStamp: ClineLogStamp?
    private var metadataModel: String?
    private var metadataStamp: ClineLogStamp?
    private static let maximumBytes = 67_108_864

    init(url: URL) {
        self.url = url
        cli = url.lastPathComponent != "ui_messages.json"
        let path = url.path
        clientName = path.contains("/rooveterinaryinc.roo-cline/") ? "Roo Code" : path.contains("/kilocode.kilo-code/") ? "Kilo Code" : nil
    }

    func read(tailLimit: Int, now: Date) {
        let folder = url.deletingLastPathComponent()
        if cli {
            let manifestURL = folder.appendingPathComponent("\(folder.lastPathComponent).json")
            let current = [ClineLogStamp(url), ClineLogStamp(manifestURL)]
            guard let messagesStamp = current[0], messagesStamp != stamp || current[1] != manifestStamp else { return }
            stamp = messagesStamp
            manifestStamp = current[1]
            guard let messages = Self.messages(url) else { return }
            let manifest = Self.object(manifestURL, limit: 1_048_576)
            cwd = Self.path(manifest?["cwd"]) ?? cwd
            summary = ClineLogSummary(cli: messages, manifest: manifest)
            return
        }
        guard let current = ClineLogStamp(url), current != stamp else { return }
        // A large task rewritten while it streams is summarised at most every 5 s.
        if current.size > 8_388_608, let parsedAt, now.timeIntervalSince(parsedAt) < 5 { return }
        stamp = current
        parsedAt = now
        guard let messages = Self.messages(url) else { return }
        summary = ClineLogSummary(task: messages)
        if summary?.model == nil { readTaskMetadata(folder) }
        if (cwd == nil && !cwdSearched) || (summary?.model == nil && metadataModel == nil) { readHistory(folder) }
    }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard let summary, let last = summary.lastAt else { return [] }
        var reading = TokenReading(source: .cline, id: id)
        reading.clientName = clientName
        reading.sessionID = url.deletingLastPathComponent().lastPathComponent
        if let cwd {
            reading.project = URL(fileURLWithPath: cwd).lastPathComponent
            reading.projectPath = cwd
        }
        reading.model = summary.model ?? metadataModel ?? historyModel
        reading.lastActivity = last
        reading.lastLogAt = last
        reading.measurementAt = summary.completion?.at ?? last
        reading.active = summary.isActive(at: now)
        reading.activityState = summary.state(at: now)
        if summary.open, let tool = summary.tool {
            reading.toolName = tool.name
            reading.toolCategory = tool.category
        }
        reading.currentTurnStartedAt = summary.open ? summary.turnStartedAt : nil
        reading.currentTurnOutputTokens = summary.open ? summary.turnOutput : nil
        reading.lastOutputAt = summary.events.last?.at
        reading.lastOutputDelta = summary.events.last?.tokens
        reading.recentOutputs = summary.events.filter {
            let age = now.timeIntervalSince($0.at)
            return age >= -5 && age <= TokenTracker.recentOutputWindow
        }
        reading.lastOutputTokens = summary.completion?.output
        reading.sampledAt = now
        return [reading]
    }

    func isRecent(at now: Date) -> Bool {
        guard let summary else { return false }
        return summary.open || summary.lastAt.map { now.timeIntervalSince($0) <= 3_600 } == true
    }

    /// Cline's older tasks name the model only in `task_metadata.json` (`model_usage[].model_id`).
    private func readTaskMetadata(_ folder: URL) {
        let metadataURL = folder.appendingPathComponent("task_metadata.json")
        guard let current = ClineLogStamp(metadataURL), current != metadataStamp else { return }
        metadataStamp = current
        let usage = Self.object(metadataURL, limit: 4_194_304)?["model_usage"] as? [[String: Any]]
        metadataModel = usage?.lazy.reversed().compactMap { ClineLogSummary.model($0["model_id"]) }.first ?? metadataModel
    }

    /// The working directory from the first request's environment details (Cline "Current Working Directory (…) Files",
    /// Roo Code and Kilo Code "Current Workspace Directory (…) Files"), and Roo Code's `<model>…</model>` from the newest one.
    /// The head is read in 1 MB steps (pasted images and attached files come first) until the marker, the first reply or
    /// 8 MB; the tail is bounded. Only the text between the markers is decoded.
    private func readHistory(_ folder: URL) {
        let historyURL = folder.appendingPathComponent("api_conversation_history.json")
        guard let current = ClineLogStamp(historyURL), current != historyStamp,
              let handle = try? FileHandle(forReadingFrom: historyURL) else { return }
        historyStamp = current
        defer { try? handle.close() }
        if cwd == nil, !cwdSearched {
            var head = Data()
            while head.count < 8_388_608, let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                head.append(chunk)
                cwd = Self.between(head, ["Current Working Directory (", "Current Workspace Directory ("], ") Files", last: false)
                    .flatMap { Self.path($0) }
                if cwd != nil { break }
                if head.range(of: Data(#""role":"assistant""#.utf8)) != nil || head.count >= 8_388_608 {
                    cwdSearched = true
                    break
                }
            }
        }
        let size = UInt64(current.size)
        guard summary?.model == nil, metadataModel == nil, (try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)) != nil,
              let tail = try? handle.readToEnd() else { return }
        historyModel = Self.between(tail, ["<model>"], "</model>", last: true).flatMap(ClineLogSummary.model) ?? historyModel
    }

    /// The JSON-escaped text between a start marker and `end`, decoded; the first match, or the last one.
    private static func between(_ data: Data, _ starts: [String], _ end: String, last: Bool) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let ranges = starts.compactMap { text.range(of: $0, options: last ? .backwards : []) }
        guard let start = last ? ranges.max(by: { $0.lowerBound < $1.lowerBound }) : ranges.min(by: { $0.lowerBound < $1.lowerBound }),
              let close = text.range(of: end, range: start.upperBound..<text.endIndex),
              text.distance(from: start.upperBound, to: close.lowerBound) <= 4_096 else { return nil }
        let escaped = "\"" + text[start.upperBound..<close.lowerBound] + "\""
        return (try? JSONSerialization.jsonObject(with: Data(escaped.utf8), options: .fragmentsAllowed)) as? String
    }

    private static func path(_ value: Any?) -> String? {
        guard let path = value as? String, !path.isEmpty, path.count <= 4_096 else { return nil }
        return path
    }

    /// The message array (the CLI may wrap it as `{messages: […]}`); nil when unreadable or oversized.
    private static func messages(_ url: URL) -> [[String: Any]]? {
        guard let data = contents(url, limit: maximumBytes),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return value as? [[String: Any]] ?? (value as? [String: Any])?["messages"] as? [[String: Any]]
    }

    private static func object(_ url: URL, limit: Int) -> [String: Any]? {
        contents(url, limit: limit).flatMap(LogFields.object)
    }

    private static func contents(_ url: URL, limit: Int) -> Data? {
        guard let stamp = ClineLogStamp(url), stamp.size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// A snapshot file's modification time and size; either changing means it was rewritten.
private struct ClineLogStamp: Equatable {
    let modified: TimeInterval
    let size: Int

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        size = Int(info.st_size)
    }
}

/// Turn state and token counts of one task, derived from message kinds, `ts` (ms) and request counts only.
private struct ClineLogSummary {
    var model: String?
    var lastAt: Date?
    var open = false
    var waiting: TokenActivityState = .idle
    var turnStartedAt: Date?
    var turnOutput = 0
    var completion: (output: Int, at: Date)?
    var events: [TokenOutputEvent] = []
    var tool: (name: String, category: ToolCategory)?

    /// Asks that end the turn: the task finished, or the model's plan-mode reply waits for the next prompt.
    private static let finishingAsks: Set<String> = ["completion_result", "resume_completed_task", "plan_mode_respond"]
    /// Asks that hold an open turn until the person answers: questions, approvals, and failures that offer a retry.
    private static let inputAsks: Set<String> = ["followup", "command", "tool", "use_mcp_server", "browser_action_launch",
        "act_mode_respond", "new_task", "condense", "summarize_task", "report_bug", "use_subagents", "api_req_failed",
        "mistake_limit_reached", "auto_approval_max_req_reached"]
    /// Messages a person or a new request writes; only these reopen a finished task.
    private static let openingSays: Set<String> = ["task", "user_feedback", "user_feedback_diff", "api_req_started"]

    /// `ui_messages.json` of a Cline, Roo Code or Kilo Code task.
    init(task messages: [[String: Any]]) {
        // A finished request's output is placed at its last message, the closest logged time to its end.
        var pending: Int?
        var pendingAt: Date?
        func flush() {
            if let tokens = pending, let at = pendingAt { record(tokens, at: at) }
            pending = nil
        }
        // Only the last message of an open turn decides its tool and state.
        var last: (say: String?, ask: String?, partial: Bool, text: Any?)?
        for (index, message) in messages.enumerated() {
            guard let at = LogFields.milliseconds(message["ts"]) else { continue }
            lastAt = max(lastAt ?? at, at)
            if let info = message["modelInfo"] as? [String: Any], let id = Self.model(info["modelId"]) { model = id }
            let partial = message["partial"] as? Bool == true
            let say = message["type"] as? String == "say" ? message["say"] as? String : nil
            let ask = message["type"] as? String == "ask" ? message["ask"] as? String : nil
            var request: [String: Any]?
            if say == "api_req_started" {
                flush()
                request = (message["text"] as? String).flatMap { Self.json($0) }
            }
            if !open, (say.map(Self.openingSays.contains) == true || (index == 0 && say == "text")) {
                open = true
                turnStartedAt = at
                turnOutput = 0
                tool = nil
            }
            if let request {
                if let tokens = LogFields.count(request["tokensOut"]), tokens > 0 {
                    turnOutput += tokens
                    pending = tokens
                }
                if request["cancelReason"] is String {
                    open = false
                    waiting = .interrupted
                }
            }
            pendingAt = at
            guard open else { continue }
            if let ask, !partial {
                // A Roo Code or Kilo Code subtask ends by asking to hand its result back to the parent (`finishTask`).
                if Self.finishingAsks.contains(ask)
                    || (ask == "tool" && (message["text"] as? String)?.contains("finishTask") == true
                        && Self.toolName(message["text"]) == "finishTask") {
                    completion = (turnOutput, at)
                    open = false
                    waiting = .complete
                    last = nil
                    continue
                }
                if ask == "resume_task" {
                    open = false
                    waiting = .interrupted
                    last = nil
                    continue
                }
            }
            last = (say, ask, partial, message["text"])
        }
        if open, let last {
            tool = Self.tool(say: last.say, ask: last.ask, partial: last.partial, text: last.text)
            waiting = tool?.category == .agent ? .tool : Self.state(say: last.say, ask: last.ask, partial: last.partial)
        }
        flush()
    }

    /// `<id>.messages.json` of a Cline CLI session with its manifest: the manifest status says whether a turn runs.
    init(cli messages: [[String: Any]], manifest: [String: Any]?) {
        var lastToolUse: String?
        for message in messages {
            guard let at = LogFields.milliseconds(message["ts"]) else { continue }
            lastAt = max(lastAt ?? at, at)
            if let info = message["modelInfo"] as? [String: Any], let id = Self.model(info["id"]) { model = id }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let types = blocks.compactMap { $0["type"] as? String }
            switch message["role"] as? String {
            case "user" where message["content"] is String || (types.contains("text") && !types.contains("tool_result")):
                turnStartedAt = at
                turnOutput = 0
                lastToolUse = nil
            case "assistant":
                if let tokens = LogFields.count((message["metrics"] as? [String: Any])?["outputTokens"]), tokens > 0 {
                    turnOutput += tokens
                    record(tokens, at: at)
                }
                lastToolUse = blocks.last(where: { ["tool_use", "tool_call", "tool-call"].contains($0["type"] as? String ?? "") })
                    .map { TokenLogParser.label($0["name"]) ?? "tool" }
            default:
                // A tool result answers the call; the model works again.
                if !types.isEmpty || message["role"] as? String == "tool" { lastToolUse = nil }
            }
        }
        if model == nil { model = Self.model(manifest?["model"]) }
        switch manifest?["status"] as? String {
        case "running", "starting", "pending", "stopping":
            open = true
            if let name = lastToolUse {
                tool = (name, TokenLogParser.category(name))
                waiting = .tool
            } else { waiting = .working }
        case "cancelled", "failed", "error": waiting = .interrupted
        default:
            waiting = .complete
            if let at = TokenLogParser.date(manifest?["ended_at"]) ?? lastAt, turnStartedAt != nil {
                completion = (turnOutput, at)
            }
        }
    }

    private mutating func record(_ tokens: Int, at: Date) {
        events.append(TokenOutputEvent(at: at, tokens: tokens))
        if events.count > 512 { events.removeFirst(events.count - 512) }
    }

    /// How long an open turn may stay silent and still count as running; a question or approval waits for the person, and
    /// a Roo Code or Kilo Code parent waits for its subtask as long as that runs.
    private var liveHorizon: TimeInterval {
        switch waiting {
        case .input: return 86_400
        case .tool: return tool?.category == .agent ? 3_600 : 900
        default: return 600
        }
    }

    func isActive(at now: Date) -> Bool {
        guard open, let lastAt else { return false }
        let age = now.timeIntervalSince(lastAt)
        return age >= -5 && age <= liveHorizon
    }

    func state(at now: Date) -> TokenActivityState {
        guard open else { return waiting }
        if isActive(at: now) { return waiting }
        if waiting == .input { return .unfinished }
        guard let lastAt, now.timeIntervalSince(lastAt) <= 1_800 else { return .unfinished }
        return .stale
    }

    private static func state(say: String?, ask: String?, partial: Bool) -> TokenActivityState {
        if partial { return .output }
        if let ask { return inputAsks.contains(ask) ? .input : ask == "command_output" ? .tool : .working }
        switch say {
        case "command", "command_output", "tool", "browser_action", "browser_action_launch", "use_mcp_server",
             "mcp_server_request_started": return .tool
        default: return .working
        }
    }

    private static func tool(say: String?, ask: String?, partial: Bool, text: Any?) -> (name: String, category: ToolCategory)? {
        // An approved `newTask` ask is the parent's last record while its subtask runs.
        if ask == "tool", !partial, toolName(text) == "newTask" { return ("newTask", .agent) }
        if let ask, !partial, inputAsks.contains(ask) { return (ask, .question) }
        switch ask ?? say {
        case "command", "command_output": return ("command", .command)
        case "browser_action", "browser_action_launch": return ("browser", .web)
        case "use_mcp_server", "mcp_server_request_started": return ("mcp", .mcp)
        case "tool":
            // The tool's own name ("readFile", "editedExistingFile"); its paths and content are not kept.
            let name = toolName(text) ?? "tool"
            return (name, name.hasPrefix("web") ? .web : ["File", "file", "Diff", "Definition"].contains { name.contains($0) } ? .file : .other)
        default: return nil
        }
    }

    /// The `tool` field of a tool message's JSON text.
    static func toolName(_ text: Any?) -> String? {
        (text as? String).flatMap { json($0) }.flatMap { label($0["tool"]) }
    }

    private static func label(_ value: Any?) -> String? { TokenLogParser.label(value) }

    static func model(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), (1...128).contains(text.count),
              !text.contains("\n") else { return nil }
        return text
    }

    private static func json(_ text: String) -> [String: Any]? { LogFields.object(Data(text.utf8)) }
}
