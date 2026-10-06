import CommonCrypto
import Foundation

// Gemini CLI and Qwen Code (a Gemini CLI fork) chat logs. Only ids, counts, times, statuses, tool and model names and the
// client's own session title are read;
// message text, tool arguments and results never leave the parsed record. Neither client logs when generation started or
// ended, so no speed is ever derived from these logs; a measured speed comes only from the client's own telemetry
// (`api_response`, Telemetry.swift) once TelemetrySetup connected it, joined to these rows by session ID.

/// The output count rule both the chat logs and the telemetry `api_response` use.
enum GeminiTokens {
    /// Output = candidates, plus thoughts when the total shows they were counted apart (Gemini API). OpenAI-compatible
    /// providers already include reasoning in the candidates, so it is not added twice.
    static func output(candidates: Int?, thoughts: Int?, prompt: Int?, total: Int?) -> Int {
        let base = candidates ?? 0
        guard let thoughts, thoughts > 0, let total, total >= (prompt ?? 0) + base + thoughts else { return base }
        return base + thoughts
    }
}

extension TokenLogFormat {
    /// `<root>/<project>/chats/session-*.jsonl` (legacy `session-*.json` snapshots until resumed), and subagents in
    /// `chats/<parent session id>/<session id>.jsonl`. The project folder holds `.project_root` with the project path.
    static let gemini = TokenLogFormat(files: { roots, discovery in
        var main: [URL] = []
        var subagents: [URL] = []
        for project in roots.flatMap(discovery.children) {
            let entries = discovery.children(project.appendingPathComponent("chats"))
            let jsonl = Set(entries.filter { $0.pathExtension == "jsonl" }.map(\.lastPathComponent))
            main.append(contentsOf: entries.filter { entry in
                // A resumed legacy snapshot is migrated to `<name>.jsonl` and left in place; only the migrated log counts.
                entry.lastPathComponent.hasPrefix("session-") && (entry.pathExtension == "jsonl"
                    || (entry.pathExtension == "json" && !jsonl.contains(entry.lastPathComponent + "l")))
            })
            for parent in entries where parent.pathExtension.isEmpty {
                subagents.append(contentsOf: discovery.children(parent).filter { $0.pathExtension == "jsonl" })
            }
        }
        return discovery.recent(main) + discovery.recent(subagents, keepingSince: discovery.now.addingTimeInterval(-3_600))
    }, isLog: { path in
        let parts = path.split(separator: "/")
        guard parts.count >= 3, let name = parts.last else { return false }
        if parts[parts.count - 2] == "chats" {
            return name.hasPrefix("session-") && (name.hasSuffix(".jsonl") || name.hasSuffix(".json"))
        }
        return parts[parts.count - 3] == "chats" && name.hasSuffix(".jsonl")
    }, open: { GeminiChatReader(url: $0) })

    /// `<root>/<project>/chats/<session id>.jsonl`, and background subagents in
    /// `<root>/<project>/subagents/<session id>/agent-<id>.jsonl` beside an `agent-<id>.meta.json` sidecar.
    static let qwen = TokenLogFormat(files: { roots, discovery in
        var main: [URL] = []
        var subagents: [URL] = []
        for project in roots.flatMap(discovery.children) {
            main.append(contentsOf: discovery.children(project.appendingPathComponent("chats")).filter { $0.pathExtension == "jsonl" })
            for session in discovery.children(project.appendingPathComponent("subagents")) where session.pathExtension.isEmpty {
                subagents.append(contentsOf: discovery.children(session).filter {
                    $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-")
                })
            }
        }
        return discovery.recent(main) + discovery.recent(subagents, keepingSince: discovery.now.addingTimeInterval(-3_600))
    }, isLog: { path in
        let parts = path.split(separator: "/")
        guard parts.count >= 3, let name = parts.last, name.hasSuffix(".jsonl") else { return false }
        return parts[parts.count - 2] == "chats" || (name.hasPrefix("agent-") && parts[parts.count - 3] == "subagents")
    }, open: { QwenChatReader(url: $0) })
}

/// Turn bookkeeping shared by both clients. Neither writes an explicit turn end in an interactive session, so a reply
/// without a tool call closes the turn softly: a later tool record or tool result in the same turn reopens it.
private final class ChatTurnState {
    let source: TokenSource
    var sessionID: String?
    var parentSessionID: String?
    var agentID: String?
    var agentRole: String?
    var project: String?
    var projectPath: String?
    var model: String?
    /// Gemini CLI's generated `summary` (metadata or a `$set` update); Qwen Code's newest `custom_title` (a `/rename` or
    /// an auto title).
    var title: String?
    var isSubagent = false
    private(set) var lastActivity: Date?
    private(set) var lastLogAt: Date?
    private var contextUsage: TokenContextUsage?
    private var compactedAt: Date?
    private var open = false
    private var startedAt: Date?
    /// The message that began the open turn: a rollback that removes it cancelled the turn.
    private(set) var turnMessageID: String?
    /// The person's input of the current turn was read, so its output count is complete.
    private var startSeen = false
    private var output = 0
    private var turnHasOutput = false
    private var observedState: TokenActivityState = .idle
    /// Outstanding tool calls in call order, id → name. Inputs are never read.
    private var tools: [(id: String, name: String?)] = []
    /// Gemini: a reply that asked for tools the client records only once they finish.
    private var unnamedTool = false
    private(set) var completion: TokenTurnCompletion?
    private var lastOutputAt: Date?
    private var lastOutputDelta: Int?
    private var recentOutputs: [TokenOutputEvent] = []
    /// Output already counted per message: Gemini appends a message again when its tokens or tool calls arrive.
    private var counted: [String: Int] = [:]
    /// Tools that wait for the person (Qwen's question and plan approval; Gemini's ask_user).
    private static let inputTools: Set<String> = ["ask_user_question", "ask_user", "exit_plan_mode"]

    init(source: TokenSource) { self.source = source }

    var hasTools: Bool { !tools.isEmpty }
    var isOpen: Bool { open }

    /// Whether a record at `date` still belongs to the open turn: it came within the turn's liveness horizon. Read before
    /// the record is noted.
    func continues(at date: Date?) -> Bool {
        guard open else { return false }
        guard let date, let liveAt else { return true }
        return date.timeIntervalSince(liveAt) <= liveHorizon
    }

    func setProject(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        project = URL(fileURLWithPath: path).lastPathComponent
        projectPath = path
    }

    /// A record of any kind: liveness only.
    func note(_ date: Date?) {
        if let date { lastLogAt = max(lastLogAt ?? date, date) }
    }

    /// A content record: shown as activity.
    func touch(_ date: Date?) {
        guard let date else { return }
        lastActivity = max(lastActivity ?? date, date)
        note(date)
    }

    func clamp(to ceiling: Date) {
        lastLogAt = lastLogAt.map { min($0, ceiling) }
        lastActivity = lastActivity.map { min($0, ceiling) }
    }

    /// The person's input starts a turn.
    func begin(at date: Date?, message: String? = nil) {
        open = true
        startedAt = date
        turnMessageID = message
        startSeen = date != nil
        output = 0
        turnHasOutput = false
        tools.removeAll()
        unnamedTool = false
        observedState = .working
        lastOutputAt = nil
        lastOutputDelta = nil
        touch(date)
    }

    /// A record that continues the turn (tool calls, tool results, thoughts); reopens a softly closed one.
    func resume(at date: Date?) {
        open = true
        observedState = tools.isEmpty && !unnamedTool ? .working : .tool
        touch(date)
    }

    func addTool(_ id: String, name: String?) {
        unnamedTool = false
        tools.removeAll { $0.id == id }
        tools.append((id, name))
        if tools.count > 256 { tools.removeFirst(tools.count - 256) }
    }

    func removeTool(_ id: String) {
        tools.removeAll { $0.id == id }
    }

    func clearTools() {
        tools.removeAll()
        unnamedTool = false
    }

    func awaitUnnamedTool(at date: Date?) {
        tools.removeAll()
        unnamedTool = true
        resume(at: date)
    }

    func close(_ state: TokenActivityState, at date: Date?) {
        if state == .complete, open, startSeen, turnHasOutput, let finished = date ?? lastActivity {
            completion = TokenTurnCompletion(output: output, durationSeconds: nil, finishedAt: finished, model: model)
        }
        open = false
        tools.removeAll()
        unnamedTool = false
        observedState = state
        touch(date)
    }

    func compacted(at date: Date?) {
        guard let date else { return }
        compactedAt = max(compactedAt ?? date, date)
    }

    func context(used: Int?, window: Int?, at date: Date?) {
        guard let used, used > 0, let date, contextUsage.map({ date >= $0.recordedAt }) ?? true else { return }
        contextUsage = TokenContextUsage(usedTokens: used, windowTokens: window.flatMap { $0 > 0 ? $0 : nil }, recordedAt: date)
    }

    /// `tokens` is the message's whole output; only the growth since it was last seen counts.
    func output(message id: String, tokens: Int, at date: Date?) {
        let prior = counted[id] ?? 0
        guard tokens > prior else { return }
        if counted.count >= 4_096 { counted.removeAll(keepingCapacity: true) }
        counted[id] = tokens
        let delta = tokens - prior
        if startSeen {
            output += delta
            turnHasOutput = true
        }
        lastOutputDelta = delta
        lastOutputAt = date
        guard let date else { return }
        touch(date)
        recentOutputs.append(TokenOutputEvent(at: date, tokens: delta))
        if recentOutputs.count > 512 { recentOutputs.removeFirst(recentOutputs.count - 512) }
    }

    private var waitsForInput: Bool { open && tools.contains { Self.inputTools.contains($0.name ?? "") } }
    private var liveAt: Date? { [lastLogAt, lastActivity].compactMap { $0 }.max() }

    /// The tracker's horizons: 600 s for the model, 900 s while a tool may run (shell commands, approvals), 24 h for a question.
    private var liveHorizon: TimeInterval {
        if waitsForInput { return 86_400 }
        return tools.isEmpty && !unnamedTool ? 600 : 900
    }

    func isActive(at now: Date) -> Bool {
        guard open, let liveAt else { return false }
        let age = now.timeIntervalSince(liveAt)
        return age >= -5 && age <= liveHorizon
    }

    func isRecent(at now: Date) -> Bool {
        open || liveAt.map { now.timeIntervalSince($0) <= 3_600 } == true
    }

    func activityState(at now: Date) -> TokenActivityState {
        guard open else { return observedState }
        if waitsForInput { return isActive(at: now) ? .input : .unfinished }
        if isActive(at: now) { return observedState }
        guard let liveAt, now.timeIntervalSince(liveAt) <= 1_800 else { return .unfinished }
        return .stale
    }

    func reading(id: String, now: Date) -> [TokenReading] {
        guard lastActivity != nil else { return [] }
        var reading = TokenReading(source: source, id: id)
        reading.sessionID = sessionID
        reading.parentSessionID = parentSessionID
        reading.agentID = agentID
        reading.agentRole = agentRole
        reading.isSubagent = isSubagent
        reading.project = project
        reading.projectPath = projectPath
        reading.title = title
        reading.model = model ?? completion?.model
        if open, unnamedTool || !tools.isEmpty {
            let tool = tools.last { Self.inputTools.contains($0.name ?? "") } ?? tools.last
            reading.toolName = tool?.name
            reading.toolCategory = tool?.name.map(Self.category) ?? .other
        }
        if var usage = contextUsage {
            usage.compactedAt = compactedAt
            reading.context = usage
        }
        reading.lastActivity = lastActivity
        reading.lastLogAt = lastLogAt
        reading.measurementAt = completion?.finishedAt ?? lastActivity
        reading.active = isActive(at: now)
        reading.activityState = activityState(at: now)
        reading.currentTurnStartedAt = open ? startedAt : nil
        reading.currentTurnOutputTokens = open && startSeen ? output : nil
        reading.lastOutputAt = lastOutputAt
        reading.lastOutputDelta = lastOutputDelta
        reading.recentOutputs = recentOutputs.filter {
            let age = now.timeIntervalSince($0.at)
            return age >= -5 && age <= TokenTracker.recentOutputWindow
        }
        reading.lastOutputTokens = completion?.output
        reading.sampledAt = now
        return [reading]
    }

    /// Gemini CLI and Qwen Code tool names; anything else falls back to the shared table.
    static func category(_ name: String) -> ToolCategory {
        switch name {
        case "run_shell_command", "monitor": return .command
        case "read_file", "write_file", "edit", "replace", "glob", "grep_search", "search_file_content", "list_directory",
             "read_many_files", "notebook_edit": return .file
        case "google_web_search": return .web
        case "agent", "invoke_agent", "delegate_to_agent", "task_stop", "create_sub_session": return .agent
        case "read_mcp_resource": return .mcp
        case "ask_user_question", "ask_user", "exit_plan_mode": return .question
        default: return TokenLogParser.category(name)
        }
    }

    /// Counts are capped at Int32.max as everywhere else (`LogFields.count`, the Windows build), so sums cannot overflow.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(Int32.max), double.rounded(.towardZero) == double else { return nil }
        return Int(double)
    }
}

/// New complete lines of an append-only JSONL log: a bounded first read, line reassembly, a 1 MB line cap, and a restart
/// when the file is replaced or truncated.
private final class ChatLineTail {
    let url: URL
    private var offset: UInt64 = 0
    private var identity: String?
    private var initialized = false
    private var pending = Data()
    private var dropping = false
    private let maximumLineBytes = 1_048_576

    init(url: URL) { self.url = url }

    /// `restart` runs before a replaced or truncated log is read again; `header` gets the first line when the first read
    /// starts past it (session metadata only).
    func read(tailLimit: Int, restart: () -> Void, header: (Data) -> Void, line: (Data) -> Void) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return }
        let size = UInt64(info.st_size)
        let currentIdentity = "\(info.st_dev)-\(info.st_ino)"
        if initialized && (identity != currentIdentity || size < offset) {
            offset = 0
            initialized = false
            pending.removeAll(keepingCapacity: false)
            dropping = false
            restart()
        }
        if initialized && size == offset { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        if !initialized {
            if size > UInt64(tailLimit), let head = try? handle.read(upToCount: 65_536), let newline = head.firstIndex(of: 10) {
                header(Data(head[head.startIndex..<newline]))
            }
            offset = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
            dropping = offset > 0
            identity = currentIdentity
            initialized = true
        }
        var budget = 16_777_216 + tailLimit
        do {
            while offset < size, budget > 0 {
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: min(1_048_576, Int(min(size - offset, UInt64(Int.max))))) ?? Data()
                guard !data.isEmpty else { break }
                offset += UInt64(data.count)
                budget -= data.count
                autoreleasepool { split(data, line: line) }
            }
        } catch { return }
    }

    private func split(_ data: Data, line: (Data) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !dropping {
                if pending.count + data.distance(from: start, to: end) <= maximumLineBytes {
                    pending.append(contentsOf: data[start..<end])
                } else {
                    pending.removeAll(keepingCapacity: false)
                    dropping = true
                }
            }
            guard let newline else { break }
            if !dropping, !pending.isEmpty { line(pending) }
            // One long line must not pin up to 1 MB per reader for good.
            pending.removeAll(keepingCapacity: pending.count <= 65_536)
            dropping = false
            start = data.index(after: newline)
        }
    }
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// One Gemini CLI chat: a JSONL log, or a legacy JSON snapshot rewritten in place.
private final class GeminiChatReader: TokenLogReader {
    let url: URL
    private let legacy: Bool
    private let tail: ChatLineTail
    private var state: ChatTurnState
    private var snapshot: (modified: TimeInterval, size: Int64)?
    private var seen = Set<String>()
    private var lastMessageID: String?
    /// From `.project_root`; the metadata's directories are used only without it.
    private let projectRoot: String?
    private let folderProject: String?

    init(url: URL) {
        self.url = url
        legacy = url.pathExtension == "json"
        tail = ChatLineTail(url: url)
        var chats = url.deletingLastPathComponent()
        let parent = chats.lastPathComponent
        if parent != "chats" { chats = chats.deletingLastPathComponent() }
        let projectFolder = chats.deletingLastPathComponent()
        projectRoot = Self.projectRoot(in: projectFolder)
        // Older builds named the folder by a sha256 of the path, which is no name to show.
        let name = projectFolder.lastPathComponent
        folderProject = name.count == 64 && name.allSatisfy(\.isHexDigit) ? nil : name
        state = ChatTurnState(source: .gemini)
        reset(subagentParent: parent != "chats" ? parent : nil)
    }

    private static func projectRoot(in folder: URL) -> String? {
        let file = folder.appendingPathComponent(".project_root")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.intValue <= 4_096,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") || path.contains(":\\") ? path : nil
    }

    private func reset(subagentParent: String?) {
        state = ChatTurnState(source: .gemini)
        seen.removeAll()
        lastMessageID = nil
        if let subagentParent {
            state.isSubagent = true
            state.parentSessionID = subagentParent
            state.sessionID = subagentParent
        }
        if let projectRoot { state.setProject(projectRoot) } else { state.project = folderProject }
    }

    private var subagentParent: String? { state.isSubagent ? state.parentSessionID : nil }

    /// A resumed legacy snapshot was migrated whole into `<name>.jsonl`, whose reader now counts it; the retained snapshot
    /// reader would list the same session twice.
    private var migrated: Bool { legacy && FileManager.default.fileExists(atPath: url.path + "l") }

    func isRecent(at now: Date) -> Bool { !migrated && state.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] { migrated ? [] : state.reading(id: id, now: now) }

    func read(tailLimit: Int, now: Date) {
        state.clamp(to: now.addingTimeInterval(5))
        if legacy { readSnapshot(); return }
        let parent = subagentParent
        tail.read(tailLimit: tailLimit, restart: { reset(subagentParent: parent) },
                  header: { jsonObject($0).map(metadata) },
                  line: { jsonObject($0).map(consume) })
    }

    /// Legacy snapshots are rewritten whole: reread (up to 32 MB) when the size or modification time changes.
    private func readSnapshot() {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return }
        let current = (TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9, Int64(info.st_size))
        guard snapshot.map({ $0 != current }) ?? true, current.1 <= 33_554_432 else { return }
        snapshot = current
        guard let data = try? Data(contentsOf: url), let record = jsonObject(data) else { return }
        reset(subagentParent: subagentParent)
        metadata(record)
        for message in record["messages"] as? [[String: Any]] ?? [] { autoreleasepool { self.message(message) } }
    }

    private func consume(_ record: [String: Any]) {
        if let update = record["$set"] as? [String: Any] {
            metadata(update)
            for message in update["messages"] as? [[String: Any]] ?? [] { self.message(message) }
        } else if record["$rewindTo"] is String {
            // A cancelled or failed request rolls the open turn back; otherwise the person rewound and waits to type.
            state.close(state.isOpen ? .interrupted : .idle, at: nil)
        } else if let patch = record["$patch"] as? [String: Any] {
            // A rollback that is no pure tail removes the turn's own prompt. Compression also removes messages, but
            // reorders the history (`orderIds`) around its summary, and the turn goes on.
            if state.isOpen, patch["orderIds"] == nil, let removed = patch["removeIds"] as? [String],
               let start = state.turnMessageID, removed.contains(start) {
                state.close(.interrupted, at: nil)
            }
        } else if record["id"] is String, record["type"] is String {
            message(record)
        } else if record["sessionId"] is String {
            metadata(record)
        }
    }

    private func metadata(_ record: [String: Any]) {
        if let id = record["sessionId"] as? String, !id.isEmpty {
            if state.isSubagent { state.agentID = id } else { state.sessionID = id }
        }
        if record["kind"] as? String == "subagent", !state.isSubagent {
            state.isSubagent = true
            state.agentID = state.sessionID
        }
        state.note(TokenLogParser.date(record["lastUpdated"]))
        if projectRoot == nil, let directory = (record["directories"] as? [String])?.first { state.setProject(directory) }
        if let summary = SessionTitle.clean(record["summary"]) { state.title = summary }
    }

    /// `deriveStableId(["environment-context"])`: the session-context turn every start, `/clear` and new chat records.
    static let environmentContextID: String = {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let input = Array("environment-context".utf8)
        CC_SHA256(input, CC_LONG(input.count), &digest)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }()

    private func message(_ record: [String: Any]) {
        guard let id = record["id"] as? String, let type = record["type"] as? String else { return }
        let date = TokenLogParser.date(record["timestamp"])
        let isNew = !seen.contains(id)
        if isNew {
            if seen.count >= 8_192 { seen.removeAll(keepingCapacity: true) }
            seen.insert(id)
            lastMessageID = id
        }
        let isLatest = id == lastMessageID
        let continuing = state.continues(at: date)
        state.note(date)
        switch type {
        case "user":
            guard isNew, id != Self.environmentContextID else { return }
            // Newer builds record tool results as user messages made only of functionResponse parts.
            let parts = record["content"] as? [[String: Any]] ?? []
            let responses = parts.compactMap { $0["functionResponse"] as? [String: Any] }
            if !responses.isEmpty {
                for response in responses { if let call = response["id"] as? String { state.removeTool(call) } }
                state.resume(at: date)
            } else if continuing {
                // Input inside a live turn is the client's own: "Please continue." or a compression summary.
                state.resume(at: date)
            } else {
                state.begin(at: date, message: id)
            }
        case "gemini":
            // Replies are recorded with text content; a part list is a turn the client synced from its own history
            // (a compression acknowledgement, a placeholder for an interrupted reply) and carries no turn change.
            guard !(record["content"] is [Any]) else { return }
            if let model = record["model"] as? String, !model.isEmpty { state.model = model }
            if let tokens = record["tokens"] as? [String: Any] {
                let input = ChatTurnState.integer(tokens["input"])
                state.output(message: id, tokens: GeminiTokens.output(
                    candidates: ChatTurnState.integer(tokens["output"]), thoughts: ChatTurnState.integer(tokens["thoughts"]),
                    prompt: input, total: ChatTurnState.integer(tokens["total"])), at: date)
                state.context(used: input, window: nil, at: date)
            }
            let calls = record["toolCalls"] as? [[String: Any]] ?? []
            let finished = calls.compactMap { TokenLogParser.date($0["timestamp"]) }.max()
            // An earlier message appended again (late tokens) does not move the turn.
            guard isLatest else { state.touch(finished ?? date); return }
            if !calls.isEmpty {
                state.clearTools()
                let terminal: Set<String> = ["success", "error", "cancelled"]
                for call in calls where !terminal.contains(call["status"] as? String ?? "") {
                    state.addTool(call["id"] as? String ?? UUID().uuidString, name: call["name"] as? String)
                }
                if !state.hasTools, calls.allSatisfy({ $0["status"] as? String == "cancelled" }) {
                    state.close(.interrupted, at: finished ?? date)
                } else {
                    // Finished tools go back to the model next.
                    state.resume(at: finished ?? date)
                }
            } else if record["content"] as? String == "" {
                // A reply without text is a tool request; its calls are written when they finish.
                state.awaitUnnamedTool(at: date)
            } else {
                state.close(.complete, at: date)
            }
        case "error":
            if isNew { state.close(.interrupted, at: date) }
        default:
            return
        }
    }
}

/// One Qwen Code chat or background subagent transcript.
private final class QwenChatReader: TokenLogReader {
    let url: URL
    private let tail: ChatLineTail
    private var state: ChatTurnState
    private var seen = Set<String>()
    private let subagent: (session: String, agent: String)?
    private var sidecarRead = false

    init(url: URL) {
        self.url = url
        tail = ChatLineTail(url: url)
        let name = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        subagent = folder.deletingLastPathComponent().lastPathComponent == "subagents" && name.hasPrefix("agent-")
            ? (folder.lastPathComponent, String(name.dropFirst(6))) : nil
        state = ChatTurnState(source: .qwen)
        reset()
    }

    private func reset() {
        state = ChatTurnState(source: .qwen)
        seen.removeAll()
        sidecarRead = false
        if let subagent {
            state.isSubagent = true
            state.sessionID = subagent.session
            state.parentSessionID = subagent.session
            state.agentID = subagent.agent
        }
    }

    func isRecent(at now: Date) -> Bool { state.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] { state.reading(id: id, now: now) }

    func read(tailLimit: Int, now: Date) {
        state.clamp(to: now.addingTimeInterval(5))
        readSidecar()
        tail.read(tailLimit: tailLimit, restart: reset, header: { _ in }, line: { jsonObject($0).map(consume) })
    }

    /// The subagent type from `agent-<id>.meta.json`, retried until present; its other keys are never kept.
    private func readSidecar() {
        guard subagent != nil, !sidecarRead, state.agentRole == nil else { return }
        let sidecar = url.deletingPathExtension().appendingPathExtension("meta.json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: sidecar.path))?[.size] as? NSNumber,
              size.intValue <= 65_536, let data = try? Data(contentsOf: sidecar), let object = jsonObject(data) else { return }
        sidecarRead = true
        state.agentRole = TokenLogParser.label(object["agentType"]) ?? state.agentRole
    }

    private func consume(_ record: [String: Any]) {
        state.setProject(record["cwd"] as? String)
        // Ahead of the branch filter: a branch's copied records carry the parent's title until its own is written.
        if record["type"] as? String == "system", record["subtype"] as? String == "custom_title",
           let title = SessionTitle.clean((record["systemPayload"] as? [String: Any])?["customTitle"]) {
            state.title = title
        }
        // /branch copies the parent's records into the new session; they were counted there.
        guard record["forkedFrom"] == nil else { return }
        if let uuid = record["uuid"] as? String {
            guard !seen.contains(uuid) else { return }
            if seen.count >= 8_192 { seen.removeAll(keepingCapacity: true) }
            seen.insert(uuid)
        }
        if let id = record["sessionId"] as? String, !id.isEmpty {
            state.sessionID = id
            if subagent != nil { state.parentSessionID = id }
        }
        if subagent != nil, state.agentRole == nil { state.agentRole = TokenLogParser.label(record["agentName"]) }
        let date = TokenLogParser.date(record["timestamp"])
        state.note(date)
        let subtype = record["subtype"] as? String
        let parts = (record["message"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        switch record["type"] as? String {
        case "user":
            switch subtype {
            case nil, "cron": state.begin(at: date)
            case "notification" where record["deliveredTurn"] as? Bool == true: state.begin(at: date)
            case "mid_turn_user_message": state.resume(at: date)
            default: return
            }
        case "assistant":
            if let model = record["model"] as? String, !model.isEmpty { state.model = model }
            if let usage = record["usageMetadata"] as? [String: Any] {
                let prompt = ChatTurnState.integer(usage["promptTokenCount"])
                state.output(message: record["uuid"] as? String ?? UUID().uuidString, tokens: GeminiTokens.output(
                    candidates: ChatTurnState.integer(usage["candidatesTokenCount"]),
                    thoughts: ChatTurnState.integer(usage["thoughtsTokenCount"]),
                    prompt: prompt, total: ChatTurnState.integer(usage["totalTokenCount"])), at: date)
                state.context(used: prompt, window: ChatTurnState.integer(record["contextWindowSize"]), at: date)
            }
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            for (index, call) in calls.enumerated() {
                state.addTool(call["id"] as? String ?? "\(record["uuid"] as? String ?? "")#\(index)", name: call["name"] as? String)
            }
            if !calls.isEmpty || state.hasTools {
                state.resume(at: date)
            } else if parts.contains(where: { $0["text"] is String && $0["thought"] as? Bool != true }) {
                state.close(.complete, at: date)
            } else {
                // Thoughts or usage alone: the model is still on this turn.
                state.resume(at: date)
            }
        case "tool_result":
            if let call = (record["toolCallResult"] as? [String: Any])?["callId"] as? String { state.removeTool(call) }
            for part in parts {
                if let call = (part["functionResponse"] as? [String: Any])?["id"] as? String { state.removeTool(call) }
            }
            state.resume(at: date)
        case "system":
            switch subtype {
            case "turn_result":
                switch (record["systemPayload"] as? [String: Any])?["state"] as? String {
                case "completed": state.close(.complete, at: date)
                case "cancelled", "error": state.close(.interrupted, at: date)
                default: return
                }
            case "rewind": state.close(.idle, at: date)
            case "chat_compression": state.compacted(at: date)
            default: return
            }
        default:
            return
        }
    }
}
