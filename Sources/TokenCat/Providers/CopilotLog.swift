import Foundation

/// GitHub Copilot CLI: `session-state/<session>/events.jsonl`, the persisted session event log (older builds wrote
/// `session-state/<session>.jsonl`). Every line is `{type, data, id, timestamp, parentId, agentId?}`.
/// - Turn: `user.message` opens it; `assistant.turn_start`, `assistant.message` and `tool.execution_*` keep it open;
///   `session.task_complete`, or an `assistant.turn_end` whose last message requested no tool, completes it;
///   `abort`, `session.error`, `session.resume` (the previous process ended mid-turn) and `session.shutdown` end it.
/// - Input: a pending `permission.requested` or `ask_user` tool waits for the person.
/// - Tokens: `assistant.message.outputTokens` per model call. The per-call `assistant.usage` (with its duration) is
///   ephemeral and never written, so no speed is measured.
/// - Liveness: while a turn is open, `inuse.<PID>.lock` files that all name exited processes (or that disappeared after
///   being seen) end the turn as `unfinished`.
/// - Project: `session.start`/`session.resume` `context.cwd`, `session.context_changed`, else `workspace.yaml` `cwd:`.
/// - Title: `workspace.yaml` `name:` (a rename), else `summary:` (the name the CLI generates with a model); the yaml is
///   read again whenever it changes. The `session.title_changed` event is ephemeral and never written.
extension TokenLogFormat {
    static let copilot = TokenLogFormat(files: { roots, discovery in
        var found: [URL] = []
        for root in roots {
            for entry in discovery.children(root) {
                if entry.pathExtension == "jsonl" { found.append(entry); continue }
                let events = entry.appendingPathComponent("events.jsonl")
                if FileManager.default.fileExists(atPath: events.path) { found.append(events) }
            }
        }
        return discovery.recent(found)
    }, isLog: { path in
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent == "events.jsonl"
            || (url.pathExtension == "jsonl" && url.deletingLastPathComponent().lastPathComponent == "session-state")
    }, open: { CopilotLogReader(url: $0) })
}

final class CopilotLogReader: TokenLogReader {
    private let tail: LogLineTail
    private let folder: URL?
    private var turn = LogTurnState(inputTools: ["ask_user"])
    private var sessionID: String?
    private var model: String?
    private var effort: String?
    private var cwd: String?
    private var workspaceStamp: String?
    private var title: String?
    /// The last model reply of the open turn requested tools, so a turn_end continues the agent loop.
    private var requestedTools = false
    /// Lock files were seen for this session, so their absence means the process is gone.
    private var lockSeen = false

    init(url: URL) {
        tail = LogLineTail(url: url)
        let isFolderLog = url.lastPathComponent == "events.jsonl"
        folder = isFolderLog ? url.deletingLastPathComponent() : nil
        sessionID = isFolderLog ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    func isRecent(at now: Date) -> Bool { turn.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard var reading = turn.reading(source: .copilot, id: id, model: model, cwd: cwd, now: now) else { return [] }
        reading.sessionID = sessionID
        reading.effort = effort
        reading.title = title
        return [reading]
    }

    func read(tailLimit: Int, now: Date) {
        turn.clamp(to: now.addingTimeInterval(5))
        let wasInitial = tail.modified == nil
        tail.read(tailLimit: tailLimit, reset: {
            turn = LogTurnState(inputTools: ["ask_user"])
            model = nil
            effort = nil
            requestedTools = false
        }) { line in
            consume(line)
        }
        if wasInitial, tail.skippedHead, let header = tail.firstLine() {
            consumeHeader(header)
        }
        readWorkspace()
        if turn.turnOpen, processEnded() { turn.close(.unfinished, at: nil, model: model) }
    }

    /// Identity, project and model from a `session.start` the tail skipped; no turn state.
    private func consumeHeader(_ data: Data) {
        guard let record = LogFields.object(data), record["type"] as? String == "session.start",
              let payload = record["data"] as? [String: Any] else { return }
        sessionID = LogFields.text(payload["sessionId"]) ?? sessionID
        if cwd == nil { cwd = LogFields.text((payload["context"] as? [String: Any])?["cwd"]) }
        if model == nil { model = LogFields.text(payload["selectedModel"]) }
    }

    private func consume(_ data: Data) {
        guard let record = LogFields.object(data), let type = record["type"] as? String,
              record["ephemeral"] as? Bool != true else { return }
        let payload = record["data"] as? [String: Any] ?? [:]
        let date = LogFields.date(record["timestamp"])
        turn.logged(date)
        // Subagent events: their output counts toward this session, their lifecycle is the parent's running tool.
        let fromSubagent = record["agentId"] is String || payload["parentToolCallId"] is String
        switch type {
        case "session.start", "session.resume":
            sessionID = LogFields.text(payload["sessionId"]) ?? sessionID
            cwd = LogFields.text((payload["context"] as? [String: Any])?["cwd"]) ?? cwd
            model = LogFields.text(payload["selectedModel"]) ?? model
            effort = TokenLogParser.label(payload["reasoningEffort"]) ?? effort
            if type == "session.resume" { turn.close(.interrupted, at: date, model: model) }
        case "session.model_change":
            model = LogFields.text(payload["newModel"]) ?? model
            effort = TokenLogParser.label(payload["reasoningEffort"]) ?? effort
        case "session.context_changed":
            cwd = LogFields.text(payload["cwd"]) ?? cwd
        case "user.message":
            guard !fromSubagent else { return }
            requestedTools = false
            turn.begin(at: date)
        case "assistant.turn_start":
            guard !fromSubagent else { return }
            turn.resume(at: date)
            requestedTools = false
            turn.setState(turn.hasPendingTools ? .tool : .working, at: date)
        case "assistant.message":
            if let used = LogFields.text(payload["model"]), !fromSubagent { model = used }
            if !fromSubagent {
                turn.resume(at: date)
                requestedTools = (payload["toolRequests"] as? [Any])?.isEmpty == false
                turn.setState(requestedTools ? .working : .output, at: date)
            }
            if let tokens = LogFields.count(payload["outputTokens"]) { turn.addOutput(tokens, at: date) }
        case "tool.execution_start":
            guard !fromSubagent, let id = LogFields.text(payload["toolCallId"]) else { return }
            turn.resume(at: date)
            turn.startTool(id, name: LogFields.text(payload["toolName"]), at: date)
        case "tool.execution_complete":
            guard !fromSubagent, let id = LogFields.text(payload["toolCallId"]) else { return }
            if let used = LogFields.text(payload["model"]) { model = used }
            turn.finishTool(id, at: date)
        case "permission.requested":
            guard let id = LogFields.text(payload["requestId"]) else { return }
            turn.resume(at: date)
            turn.startRequest(id, at: date)
        case "permission.completed":
            if let id = LogFields.text(payload["requestId"]) { turn.finishRequest(id) }
        case "assistant.turn_end":
            guard !fromSubagent else { return }
            if !requestedTools, !turn.hasPendingTools { turn.close(.complete, at: date, model: model) }
        case "session.task_complete":
            guard !fromSubagent else { return }
            turn.close(.complete, at: date, model: model)
        case "abort", "session.error":
            guard !fromSubagent else { return }
            turn.close(.interrupted, at: date, model: model)
        case "session.shutdown":
            model = LogFields.text(payload["currentModel"]) ?? model
            turn.close(.interrupted, at: date, model: model)
        default: break
        }
    }

    /// `cwd:` (when the events named none), `name:` and `summary:` from workspace.yaml (plain, quoted or block scalars
    /// on top-level keys), whenever its size, time or file changed; its other keys are never kept.
    private func readWorkspace() {
        guard let folder else { return }
        let file = folder.appendingPathComponent("workspace.yaml")
        var info = stat()
        guard stat(file.path, &info) == 0 else { return }
        let current = "\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        guard current != workspaceStamp else { return }
        workspaceStamp = current
        guard info.st_size <= 65_536, let data = try? Data(contentsOf: file) else { return }
        let values = Self.yamlValues(String(decoding: data, as: UTF8.self), keys: ["cwd", "name", "summary"])
        if cwd == nil, let path = values["cwd"], !path.isEmpty { cwd = path }
        title = SessionTitle.clean(values["name"]) ?? SessionTitle.clean(values["summary"])
    }

    /// Top-level scalar values of a flat YAML mapping, for the given keys only.
    static func yamlValues(_ text: String, keys: Set<String>) -> [String: String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var values: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let colon = line.firstIndex(of: ":"), line.first?.isWhitespace == false else { continue }
            let key = String(line[..<colon])
            guard keys.contains(key) else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let first = value.first, first == "|" || first == ">" {
                // A block scalar: the indented lines that follow, joined (SessionTitle folds them to one line anyway).
                var block: [String] = []
                while index < lines.count, lines[index].isEmpty || lines[index].first?.isWhitespace == true {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                values[key] = block.joined(separator: "\n")
            } else if value.count >= 2, value.first == "\"", value.last == "\"" {
                values[key] = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) as? String
                    ?? String(value.dropFirst().dropLast())
            } else if value.count >= 2, value.first == "'", value.last == "'" {
                values[key] = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else {
                values[key] = value
            }
        }
        return values
    }

    /// The CLI keeps `inuse.<PID>.lock` in the session folder while it runs; a crash can leave one behind.
    private func processEnded() -> Bool {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let pids = names.compactMap { name -> pid_t? in
            guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { return nil }
            return pid_t(String(name.dropFirst(6).dropLast(5)))
        }
        if pids.isEmpty { return lockSeen }
        lockSeen = true
        return !pids.contains { $0 > 0 && (kill($0, 0) == 0 || errno == EPERM) }
    }
}
