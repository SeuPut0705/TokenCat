import Foundation

/// Grok Build (xAI's `grok` CLI): one folder per session, `$GROK_HOME/sessions/<encoded cwd>/<session id>/` (default
/// `~/.grok`). The cwd folder is the URL-encoded path, or a slug plus hash with the path in its `.cwd` file. Field names
/// follow xai-org/grok-build (`xai-grok-session-events`, `session/persistence.rs`, `extensions/notification.rs`).
/// - `events.jsonl` (append-only): `turn_started` (`model_id`), `loop_started`/`first_token`/`phase_changed`,
///   `tool_started`/`tool_completed` (`tool_name`; the start carries no call id), `permission_requested`/
///   `permission_resolved` (a tool waits for the person's approval), `turn_ended` (`outcome`: completed, cancelled,
///   error, interrupted). These drive the turn state.
/// - `updates.jsonl` (the ACP update stream, the tracked log): only `turn_completed` is read — its `usage.outputTokens`
///   counts a turn the unified log did not cover (it includes subagents that finished within the turn) and `elapsed_ms`
///   is the client's turn duration. Chunk lines are skipped before decoding; `agent_result` is never kept.
/// - `summary.json` (rewritten whole): `info.cwd`, `current_model_id`, `reasoning_effort`, `context_window`,
///   `generated_title` (generated after the first prompt, or `title_is_manual` after `/rename`; when the title request
///   fails Grok stores the prompt's opening words, which are never shown; `session_summary` is never read),
///   `session_kind` (`subagent…` marks a subagent; `fork` and `worktree` sessions stay top-level) and `parent_session_id`.
/// - Subagents: the parent writes `<parent>/subagents/<child id>/meta.json` (`parent_session_id`, `subagent_type`); the
///   child is an ordinary session folder, under another cwd folder when it runs in a worktree.
/// - `$GROK_HOME/logs/unified.jsonl` (all sessions, trimmed to half at 5 MB): each `shell.turn.inference_done` line
///   (`sid`) gives one model call's `completion_tokens` (reasoning included) at its log time, `prompt_tokens` (the context
///   in use) and the client's own call timing `model_elapsed_ms` (first token included; `attempts` > 1 includes retries)
///   with `ttft_ms` — the measured request rate. Nothing is estimated from log times.
extension TokenLogFormat {
    static let grok = TokenLogFormat(files: { roots, discovery in
        var found: [URL] = []
        for root in roots {
            for group in discovery.children(root) where discovery.isFolder(group) {
                for session in discovery.children(group) where discovery.isFolder(session) {
                    let log = session.appendingPathComponent("updates.jsonl")
                    if FileManager.default.fileExists(atPath: log.path) { found.append(log) }
                }
            }
        }
        return discovery.recent(found)
    }, isLog: { $0.hasSuffix("/updates.jsonl") && !$0.contains("/subagents/") }, open: { GrokLogReader(url: $0) })
}

final class GrokLogReader: TokenLogReader {
    /// Tools that wait for the person rather than run.
    static let inputTools: Set<String> = ["ask_user_question", "exit_plan_mode"]

    private let directory: URL
    private let sessionID: String
    private let unified: GrokUnifiedLog
    private var events: LogLineTail
    private var updates: LogLineTail
    private var unifiedCursor = 0
    private var turn = LogTurnState(inputTools: GrokLogReader.inputTools)
    /// A `turn_started` or `turn_ended` was read, so later activity outside a turn is not a turn whose start was skipped.
    private var sawBoundary = false
    private var pendingTools: [(id: String, name: String)] = []
    private var toolSerial = 0
    /// The open turn got output from the unified log, so its `turn_completed` usage is not counted again.
    private var turnCallOutput = false
    /// A `turn_completed` usage counted the turn ending here; unified calls up to it are not counted again.
    private var accountedThrough: Date?
    private var lastTurnSeconds: Double?
    private var turnModel: String?
    private var context: TokenContextUsage?
    private var measurement: TokenSpeedMeasurement?

    private var summaryStamp: String?
    private var cwd: String?
    private var summaryModel: String?
    private var effort: String?
    private var title: String?
    /// The generated title last compared with the first prompt, and whether the comparison could be made.
    private var checkedTitle: (generated: String?, verified: Bool)?
    private var windowTokens: Int?
    private var isSubagent = false
    private var parentSessionID: String?
    private var agentRole: String?
    private var metaFound = false
    private var parentSearchedAt: Date?

    init(url: URL) {
        directory = url.deletingLastPathComponent()
        sessionID = directory.lastPathComponent
        events = LogLineTail(url: directory.appendingPathComponent("events.jsonl"))
        updates = LogLineTail(url: url)
        let sessions = directory.deletingLastPathComponent().deletingLastPathComponent()
        unified = GrokUnifiedLog.shared(sessions.deletingLastPathComponent().appendingPathComponent("logs/unified.jsonl"))
    }

    func isRecent(at now: Date) -> Bool { turn.isRecent(at: now) }

    private var model: String? { turn.turnOpen ? turnModel ?? summaryModel : summaryModel ?? turnModel }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard var reading = turn.reading(source: .grok, id: id, model: model, cwd: cwd, now: now) else { return [] }
        reading.sessionID = sessionID
        reading.title = title
        reading.effort = effort
        if let tool = turn.runningTool { reading.toolCategory = tool.name.map(Self.category) ?? .other }
        if isSubagent {
            reading.isSubagent = true
            reading.parentSessionID = parentSessionID
            reading.agentID = sessionID
            reading.agentRole = agentRole
        }
        if var usage = context {
            usage.windowTokens = windowTokens
            reading.context = usage
        }
        reading.speedMeasurement = measurement
        if reading.lastOutputTokens != nil { reading.lastTurnDurationSeconds = lastTurnSeconds }
        return [reading]
    }

    func read(tailLimit: Int, now: Date) {
        turn.clamp(to: now.addingTimeInterval(5))
        readSummary()
        unified.refresh(tailLimit: tailLimit)
        if let steps = collect(tailLimit: tailLimit) {
            apply(steps)
        } else {
            restart()
            if let steps = collect(tailLimit: tailLimit) { apply(steps) }
        }
        findParent(now: now)
    }

    /// A replaced or truncated events or updates file: both are read again from a bounded tail with fresh turn state.
    private func restart() {
        events = LogLineTail(url: events.url)
        updates = LogLineTail(url: updates.url)
        turn = LogTurnState(inputTools: Self.inputTools)
        sawBoundary = false
        pendingTools.removeAll()
        unifiedCursor = 0
        turnCallOutput = false
        accountedThrough = nil
        lastTurnSeconds = nil
        context = nil
        measurement = nil
    }

    private struct Step {
        enum Kind {
            case turnStarted(model: String?), activity, toolStarted(String), toolCompleted(String)
            case permissionRequested(String), permissionResolved(String), turnEnded(complete: Bool), other
            case completed(output: Int?, elapsedMs: Double?, success: Bool)
            case call(GrokUnifiedLog.Call)
        }
        let at: Date
        let kind: Kind
    }

    private static let turnCompletedMarker = Data("\"turn_completed\"".utf8)

    /// The new steps of all three logs in time order (events, then updates, then calls on equal times); nil when the
    /// events or updates file was replaced or truncated.
    private func collect(tailLimit: Int) -> [Step]? {
        var steps: [Step] = []
        var replaced = false
        events.read(tailLimit: tailLimit, reset: { replaced = true }) { line in
            if let step = Self.event(line) { steps.append(step) }
        }
        updates.read(tailLimit: tailLimit, reset: { replaced = true }) { line in
            guard line.range(of: Self.turnCompletedMarker) != nil, let step = Self.completion(line) else { return }
            steps.append(step)
        }
        if replaced { return nil }
        for call in unified.calls(for: sessionID, after: unifiedCursor) {
            steps.append(Step(at: call.at, kind: .call(call)))
            unifiedCursor = call.serial
        }
        return steps.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    private static func event(_ line: Data) -> Step? {
        guard let record = LogFields.object(line), let type = record["type"] as? String,
              let at = LogFields.date(record["ts"]) else { return nil }
        let tool = TokenLogParser.label(record["tool_name"]) ?? "tool"
        switch type {
        case "turn_started": return Step(at: at, kind: .turnStarted(model: modelName(record["model_id"])))
        case "loop_started", "first_token", "phase_changed", "interjected": return Step(at: at, kind: .activity)
        case "tool_started": return Step(at: at, kind: .toolStarted(tool))
        case "tool_completed": return Step(at: at, kind: .toolCompleted(tool))
        case "permission_requested": return Step(at: at, kind: .permissionRequested(tool))
        case "permission_resolved": return Step(at: at, kind: .permissionResolved(tool))
        case "turn_ended": return Step(at: at, kind: .turnEnded(complete: record["outcome"] as? String == "completed"))
        default: return Step(at: at, kind: .other)
        }
    }

    /// A `turn_completed` update: its usage output, turn duration and whether it ended normally. Text fields are dropped.
    private static func completion(_ line: Data) -> Step? {
        guard let record = LogFields.object(line), let params = record["params"] as? [String: Any],
              let update = params["update"] as? [String: Any], update["sessionUpdate"] as? String == "turn_completed",
              let at = LogFields.milliseconds((params["_meta"] as? [String: Any])?["agentTimestampMs"])
                ?? TokenLogParser.date(record["timestamp"]) else { return nil }
        let stop = update["stop_reason"] as? String
        let output = LogFields.count((update["usage"] as? [String: Any])?["outputTokens"])
        return Step(at: at, kind: .completed(output: output, elapsedMs: GrokUnifiedLog.milliseconds(update["elapsed_ms"]),
                                             success: stop != "cancelled" && stop != "error"))
    }

    private func apply(_ steps: [Step]) {
        for step in steps {
            let at = step.at
            turn.logged(at)
            switch step.kind {
            case .turnStarted(let name):
                sawBoundary = true
                turnModel = name ?? turnModel
                pendingTools.removeAll()
                turnCallOutput = false
                turn.begin(at: at, whole: unified.covers(at))
            case .activity:
                resumeUnseenTurn(at)
                guard turn.turnOpen else { continue }
                turn.setState(pendingTools.isEmpty ? .working : .tool, at: at)
            case .toolStarted(let name):
                resumeUnseenTurn(at)
                guard turn.turnOpen else { continue }
                toolSerial += 1
                pendingTools.append(("\(toolSerial)", name))
                if pendingTools.count > 256 { pendingTools.removeFirst(pendingTools.count - 256) }
                turn.startTool("\(toolSerial)", name: name, at: at)
            case .toolCompleted(let name):
                // Parallel calls of one tool finish in any order; the oldest of that name is closed.
                if let index = pendingTools.firstIndex(where: { $0.name == name }) {
                    turn.finishTool(pendingTools.remove(at: index).id, at: at)
                } else { turn.touch(at) }
            case .permissionRequested(let name):
                resumeUnseenTurn(at)
                turn.startRequest("permission:" + name, at: at)
            case .permissionResolved(let name):
                turn.finishRequest("permission:" + name)
                turn.touch(at)
            case .turnEnded(let complete):
                sawBoundary = true
                pendingTools.removeAll()
                turn.close(complete ? .complete : .interrupted, at: at, model: model)
            case .other:
                continue
            case let .completed(output, elapsedMs, success):
                guard success else { continue }
                if let output, output > 0, !turnCallOutput {
                    turn.addOutput(output, at: at)
                    accountedThrough = at
                }
                if let elapsedMs { lastTurnSeconds = elapsedMs / 1_000 }
            case .call(let call):
                if call.prompt > 0 { context = TokenContextUsage(usedTokens: call.prompt, windowTokens: nil, recordedAt: at) }
                guard call.output > 0, accountedThrough.map({ at > $0 }) ?? true else { continue }
                turn.addOutput(call.output, at: at)
                turnCallOutput = true
                if let duration = call.elapsedMs {
                    var speed = TokenSpeedMeasurement(TelemetryReading(provider: .grok, at: at))
                    speed.model = model
                    speed.outputTokens = call.output
                    speed.requestDurationMs = duration
                    speed.requestDurationIncludesRetries = call.retried
                    speed.ttftMs = call.ttftMs
                    measurement = speed
                }
            }
        }
    }

    /// Activity while no turn is open opens one only when its `turn_started` lay before the events tail.
    private func resumeUnseenTurn(_ at: Date) {
        if !sawBoundary && events.skippedHead { turn.resume(at: at) }
    }

    private func readSummary() {
        let url = directory.appendingPathComponent("summary.json")
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            if cwd == nil { cwd = Self.groupCwd(directory.deletingLastPathComponent()) }
            return
        }
        let current = "\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        guard current != summaryStamp else { return }
        summaryStamp = current
        guard info.st_size <= 1_048_576, let data = try? Data(contentsOf: url), let summary = LogFields.object(data) else { return }
        if let path = LogFields.text((summary["info"] as? [String: Any])?["cwd"]), path.count <= 4_096 { cwd = path }
        if cwd == nil { cwd = Self.groupCwd(directory.deletingLastPathComponent()) }
        summaryModel = Self.modelName(summary["current_model_id"]) ?? summaryModel
        effort = TokenLogParser.label(summary["reasoning_effort"])
        let generated = SessionTitle.clean(summary["generated_title"])
        if summary["title_is_manual"] as? Bool == true {
            title = generated
        } else if generated != checkedTitle?.generated || checkedTitle?.verified == false {
            let copy = generated.map(copiesFirstPrompt)
            checkedTitle = (generated, copy != nil)
            title = copy == false ? generated : nil
        }
        windowTokens = LogFields.count(summary["context_window"])
        isSubagent = (summary["session_kind"] as? String)?.hasPrefix("subagent") == true
        if isSubagent {
            parentSessionID = TokenLogParser.label(summary["parent_session_id"]) ?? parentSessionID
            if agentRole == nil { agentRole = TokenLogParser.label(summary["agent_name"]) }
        }
    }

    /// A subagent's `meta.json` in its parent's folder names the parent and the agent type. Searched in this cwd folder
    /// first, then in the others (a worktree child runs elsewhere); at most once a minute until found.
    private func findParent(now: Date) {
        guard isSubagent, !metaFound, parentSearchedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        parentSearchedAt = now
        let manager = FileManager.default
        let group = directory.deletingLastPathComponent()
        let others = ((try? manager.contentsOfDirectory(at: group.deletingLastPathComponent(), includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []).filter { $0.path != group.path }
        for folder in [group] + others {
            let sessions = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for session in sessions where session.lastPathComponent != sessionID {
                let meta = session.appendingPathComponent("subagents/\(sessionID)/meta.json")
                var info = stat()
                guard stat(meta.path, &info) == 0 else { continue }
                metaFound = true
                let record = info.st_size <= 262_144 ? (try? Data(contentsOf: meta)).flatMap(LogFields.object) : nil
                parentSessionID = TokenLogParser.label(record?["parent_session_id"]) ?? session.lastPathComponent
                agentRole = TokenLogParser.label(record?["subagent_type"]) ?? agentRole
                return
            }
        }
    }

    private static let userChunkMarker = Data("\"user_message_chunk\"".utf8)

    /// When its title request fails Grok titles the session with the first prompt's opening ten words; such a title is
    /// never shown. The first prompt is read from the head of `updates.jsonl` for this comparison only and is not kept.
    /// Nil when the head holds no prompt to compare with (the title then stays hidden until the summary changes).
    private func copiesFirstPrompt(_ title: String) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: updates.url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 262_144) else { return nil }
        var prompt = ""
        var index: Int?
        for line in head.split(separator: 10) where line.range(of: Self.userChunkMarker) != nil {
            guard let record = LogFields.object(line), let update = (record["params"] as? [String: Any])?["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "user_message_chunk" else { continue }
            let promptIndex = LogFields.count((update["_meta"] as? [String: Any])?["promptIndex"]) ?? 0
            if let index, promptIndex != index { break }
            index = promptIndex
            if let text = (update["content"] as? [String: Any])?["text"] as? String { prompt += " " + text }
        }
        guard index != nil else { return nil }
        func words(_ text: String) -> String { " " + text.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " " }
        return words(prompt).contains(words(title))
    }

    /// The cwd a session folder group stands for: its URL-decoded name, else the `.cwd` file of a slug-and-hash name.
    static func groupCwd(_ group: URL) -> String? {
        if let decoded = group.lastPathComponent.removingPercentEncoding, decoded.hasPrefix("/") { return decoded }
        guard let data = try? Data(contentsOf: group.appendingPathComponent(".cwd")), data.count <= 4_096,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    static func modelName(_ value: Any?) -> String? {
        LogFields.text(value).flatMap { $0.count <= 128 ? $0 : nil }
    }

    /// Grok Build's tool names (verified: read_file, grep, run_terminal_command, search_replace, list_dir, todo_write,
    /// write, search_tool, get_command_or_subagent_output, kill_command_or_subagent); anything else uses the shared table.
    static func category(_ name: String) -> ToolCategory {
        switch name {
        case "run_terminal_command", "get_command_or_subagent_output", "kill_command_or_subagent": return .command
        case "read_file", "write", "write_file", "edit_file", "search_replace", "apply_patch", "list_dir", "grep", "glob": return .file
        case "web_search", "web_fetch", "x_search", "open_page", "browser": return .web
        case "spawn_subagent": return .agent
        case "search_tool", "use_tool": return .mcp
        case "ask_user_question", "exit_plan_mode": return .question
        default: return TokenLogParser.category(name)
        }
    }
}

/// `$GROK_HOME/logs/unified.jsonl`, shared by every session reader of one Grok home: tailed once (a stat when nothing
/// changed) and kept as each session's recent model calls. Grok trims the file to its newer half in place; lines read
/// again after that are dropped by each session's newest call time. Only counts, durations and times are kept.
final class GrokUnifiedLog {
    struct Call {
        let serial: Int
        let at: Date
        let output: Int
        let prompt: Int
        let elapsedMs: Double?
        let ttftMs: Double?
        let retried: Bool
    }

    private static let lock = NSLock()
    private static var logs: [String: GrokUnifiedLog] = [:]
    private static let marker = Data("\"shell.turn.inference_done\"".utf8)

    private let lock = NSLock()
    private let tail: LogLineTail
    private var calls: [String: [Call]] = [:]
    private var serial = 0
    private var started = false
    private var skippedFirst = false
    /// The first line's time when the first read skipped the file's head: calls before it were never seen.
    private var coverageStart: Date?

    private init(url: URL) { tail = LogLineTail(url: url) }

    static func shared(_ url: URL) -> GrokUnifiedLog {
        lock.lock()
        defer { lock.unlock() }
        if let log = logs[url.path] { return log }
        let log = GrokUnifiedLog(url: url)
        logs[url.path] = log
        return log
    }

    func refresh(tailLimit: Int) {
        lock.lock()
        defer { lock.unlock() }
        let first = !started
        started = true
        tail.read(tailLimit: tailLimit, reset: {}) { line in
            if first, tail.skippedHead, coverageStart == nil, let record = LogFields.object(line) {
                skippedFirst = true
                coverageStart = LogFields.date(record["ts"])
            }
            consume(line)
        }
        if first, tail.skippedHead { skippedFirst = true }
    }

    /// Whether every call of a turn that started at `date` was read.
    func covers(_ date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard skippedFirst else { return true }
        return coverageStart.map { date >= $0 } ?? false
    }

    func calls(for session: String, after serial: Int) -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls[session]?.filter { $0.serial > serial } ?? []
    }

    private func consume(_ line: Data) {
        guard line.range(of: Self.marker) != nil, let record = LogFields.object(line),
              record["msg"] as? String == "shell.turn.inference_done", let session = TokenLogParser.label(record["sid"]),
              let at = LogFields.date(record["ts"]), let context = record["ctx"] as? [String: Any] else { return }
        var list = calls[session] ?? []
        if let newest = list.last?.at, at <= newest { return }
        serial += 1
        list.append(Call(serial: serial, at: at, output: LogFields.count(context["completion_tokens"]) ?? 0,
                         prompt: LogFields.count(context["prompt_tokens"]) ?? 0,
                         elapsedMs: Self.milliseconds(context["model_elapsed_ms"]), ttftMs: Self.milliseconds(context["ttft_ms"]),
                         retried: (LogFields.count(context["attempts"]) ?? 1) > 1))
        if list.count > 256 { list.removeFirst(list.count - 256) }
        calls[session] = list
        if calls.count > 512, let oldest = calls.min(by: { ($0.value.last?.at ?? .distantPast) < ($1.value.last?.at ?? .distantPast) })?.key {
            calls[oldest] = nil
        }
    }

    /// A positive, finite duration in milliseconds below a week; anything else is not a measurement.
    static func milliseconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let ms = number.doubleValue
        return ms.isFinite && ms > 0 && ms < 604_800_000 ? ms : nil
    }
}
