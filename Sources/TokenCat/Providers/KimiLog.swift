import CryptoKit
import Foundation

/// Kimi Code (Moonshot AI), the same runtime inside the Kimi desktop app (Kimi Work), and the archived kimi-cli it replaced.
/// - Kimi Code: `<KIMI_CODE_HOME | ~/.kimi-code>/sessions/<wd_slug_hash>/<session>/agents/<agent>/wire.jsonl`, one append-only
///   journal per agent (`main`; subagents `agent-0`, `agent-1`, …) beside the session's `state.json`. Each line is
///   `{"type", …payload, "time" (epoch ms)}` (MoonshotAI/kimi-code packages/agent-core-v2/docs/wire-manifest.d.ts).
///   Turn: `turn.prompt` opens it, `turn.ended` closes it (`completed`, else interrupted; its `durationMs` is the client's own
///   turn duration). `context.append_loop_event` `tool.call` → `tool.result` (by `toolCallId`) run a tool; `interaction.request`
///   of kind `approval`/`question` waits for the person until `interaction.resolved`. Output: turn-scoped `usage.record`
///   `usage.output` at its `time`; context = its input + cache counts. Model: `llm.request.model` (the id sent to the provider;
///   `usage.record.model` is only the configured alias). Speed: a `step.end`'s output over the client's own
///   `llmFirstTokenLatencyMs` + `llmStreamDurationMs`. `state.json`: `cwd` (older stores `workDir`), the title only when
///   `titleKind` is `generated` or `custom` (a `replaceable` title is the first prompt's opening; sessions imported from
///   kimi-cli carry its prompt fallbacks, so none), and a subagent's role from `agents.<id>.labels.profileName`.
/// - kimi-cli: `<KIMI_SHARE_DIR | ~/.kimi>/sessions/<md5(work dir)>/<session>/wire.jsonl`, subagents in
///   `subagents/<id>/wire.jsonl` with a `meta.json`. Lines `{"timestamp" (s), "message": {"type", "payload"}}`: TurnBegin,
///   SteerInput, StepBegin, ToolCall/ToolResult, ApprovalRequest/ApprovalResponse, QuestionRequest, StatusUpdate, StepInterrupted,
///   TurnEnd. Output from `StatusUpdate.token_usage.output`, once per `message_id` within a step; context from `context_tokens` and
///   `max_context_tokens`. Project from `kimi.json` `work_dirs[].path` whose md5 names the folder. Model: a subagent's
///   `meta.json` `launch_spec.effective_model`, else `config.toml` `default_model`'s `[models.<alias>] model`. No title (its
///   `custom_title` can hold the first prompt) and no speed (no recorded durations). Sessions Kimi Code's migration copied (written
///   before `.migrated-to-kimi-code`) are left to the Kimi Code reader.
/// Only types, ids, counts, times, tool names, model ids, the cwd and client titles are kept; message text never is.
extension TokenLogFormat {
    static let kimi = TokenLogFormat(files: { roots, discovery in
        var main: [URL] = []
        var subagents: [URL] = []
        let fileManager = FileManager.default
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        for root in roots {
            let marker = root.deletingLastPathComponent().appendingPathComponent(".migrated-to-kimi-code")
            let migrated = (try? fileManager.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date
            func legacy(_ wire: URL) -> Bool {
                guard fileManager.fileExists(atPath: wire.path) else { return false }
                guard let migrated, let written = modified(wire) else { return true }
                return written > migrated
            }
            for workspace in discovery.children(root) where discovery.isFolder(workspace) {
                for session in discovery.children(workspace) where discovery.isFolder(session) {
                    let agents = discovery.children(session.appendingPathComponent("agents"))
                    for agent in agents where discovery.isFolder(agent) {
                        let wire = agent.appendingPathComponent("wire.jsonl")
                        guard fileManager.fileExists(atPath: wire.path) else { continue }
                        if agent.lastPathComponent == KimiLog.mainAgent { main.append(wire) } else { subagents.append(wire) }
                    }
                    guard agents.isEmpty else { continue }
                    let wire = session.appendingPathComponent("wire.jsonl")
                    if legacy(wire) { main.append(wire) }
                    for agent in discovery.children(session.appendingPathComponent("subagents")) where discovery.isFolder(agent) {
                        let child = agent.appendingPathComponent("wire.jsonl")
                        if legacy(child) { subagents.append(child) }
                    }
                }
            }
        }
        // Subagents come in bursts; they get their own cap so main sessions stay visible.
        return discovery.recent(main) + discovery.recent(subagents, keepingSince: discovery.now.addingTimeInterval(-3_600))
    }, isLog: { $0.hasSuffix("/wire.jsonl") }, open: { url in
        KimiLog.isKimiCode(url) ? KimiCodeLogReader(url: url) as TokenLogReader : KimiCLILogReader(url: url)
    })
}

enum KimiLog {
    static let mainAgent = "main"

    /// `…/agents/<agent>/wire.jsonl` is Kimi Code; kimi-cli keeps `wire.jsonl` in the session folder or `subagents/<id>/`.
    static func isKimiCode(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "agents"
    }

    /// The Kimi desktop app's embedded runtime (Kimi Work) keeps its Kimi Code home under its app data.
    static func clientName(_ url: URL) -> String? {
        url.path.contains("/kimi-desktop/daimon-share/") ? "Kimi Work" : nil
    }

    static let typeKey = Array(#"{"type":""#.utf8)
    static let eventKey = Array(#""event":{"type":""#.utf8)
    static let toolCallKey = Array(#""toolCallId":""#.utf8)
    static let messageTypeKey = Array(#""message":{"type":""#.utf8)

    /// The string after `key` within the line's first `limit` bytes, so a line with long text is not parsed for one field.
    /// Nil when absent or escaped (type names and ids hold neither quotes nor backslashes).
    static func sniff(_ data: Data, _ key: [UInt8], within limit: Int, leading: Bool = false) -> String? {
        let window = data.prefix(limit)
        guard let range = window.range(of: Data(key)), !leading || range.lowerBound == window.startIndex,
              let end = window[range.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        let value = window[range.upperBound..<end]
        guard !value.isEmpty, !value.contains(UInt8(ascii: "\\")) else { return nil }
        return String(decoding: value, as: UTF8.self)
    }

    /// The `"time":<ms>}` that ends every Kimi Code record (the serializer writes it last).
    static func trailingTime(_ data: Data) -> Date? {
        var end = data.endIndex
        while end > data.startIndex, [9, 10, 13, 32].contains(data[end - 1]) { end -= 1 }
        guard end > data.startIndex, data[end - 1] == UInt8(ascii: "}") else { return nil }
        let digitsEnd = end - 1
        var start = digitsEnd
        while start > data.startIndex, (48...57).contains(data[start - 1]) { start -= 1 }
        let key = Array(#""time":"#.utf8)
        guard start < digitsEnd, data.distance(from: data.startIndex, to: start) >= key.count,
              data[(start - key.count)..<start].elementsEqual(key),
              let ms = Double(String(decoding: data[start..<digitsEnd], as: UTF8.self)) else { return nil }
        return LogFields.milliseconds(NSNumber(value: ms))
    }

    /// The `{"timestamp":<seconds>` that opens every kimi-cli record.
    static func leadingSeconds(_ data: Data) -> Date? {
        let key = Array(#"{"timestamp":"#.utf8)
        guard data.starts(with: key) else { return nil }
        let number = data.dropFirst(key.count).prefix(32).prefix { (48...57).contains($0) || $0 == UInt8(ascii: ".") }
        guard let seconds = Double(String(decoding: number, as: UTF8.self)), seconds > 0, seconds < 253_370_764_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The model id sent to the provider: a `kimi-code/` prefix dropped, symbolic config references (`__kimi_env_model__`) refused.
    static func modelName(_ value: Any?) -> String? {
        guard var name = LogFields.text(value)?.trimmingCharacters(in: .whitespaces), name.count <= 128 else { return nil }
        if name.hasPrefix("kimi-code/") { name.removeFirst("kimi-code/".count) }
        guard !name.isEmpty, !(name.count >= 4 && name.hasPrefix("__") && name.hasSuffix("__")) else { return nil }
        return name
    }

    /// A Kimi Code session title the client generated or the person set, as its own loader reads `state.json` (`title` with
    /// `titleKind`, else the older `isCustomTitle`/`customTitle`). Imported kimi-cli sessions map its prompt fallbacks to
    /// `generated`, so they have none.
    static func title(_ state: [String: Any]) -> String? {
        if (state["custom"] as? [String: Any])?["imported_from_kimi_cli"] as? Bool == true { return nil }
        if state["title"] is String {
            if state["isCustomTitle"] as? Bool == true { return SessionTitle.clean(state["title"]) }
            if let kind = state["titleKind"] as? String {
                return kind == "generated" || kind == "custom" ? SessionTitle.clean(state["title"]) : nil
            }
            return nil
        }
        return SessionTitle.clean(state["customTitle"])
    }

    /// A non-negative duration in milliseconds.
    static func duration(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    /// "<inode>-<size>-<mtime>" of a small side file, nil when it is missing.
    static func stamp(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
    }

    /// A side file of at most `limit` bytes as a JSON object.
    static func object(_ url: URL, limit: Int = 4_194_304) -> [String: Any]? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        return LogFields.object(data)
    }

    /// kimi-cli's configured model: `default_model` names a `[models.<alias>]` table whose `model` is the provider's id.
    static func configuredModel(toml: String) -> String? {
        func value(_ text: Substring) -> String {
            var text = text.trimmingCharacters(in: .whitespaces)
            if let quote = text.first, quote == "\"" || quote == "'" {
                text.removeFirst()
                if let close = text.firstIndex(of: quote) { text = String(text[..<close]) }
            } else if let comment = text.firstIndex(of: "#") {
                text = text[..<comment].trimmingCharacters(in: .whitespaces)
            }
            return text
        }
        var alias: String?
        var section: String?
        var models: [String: String] = [:]
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.dropFirst().prefix { $0 != "]" }
                section = name.hasPrefix("models.") ? value(name.dropFirst("models.".count)) : ""
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if section == nil, key == "default_model" { alias = value(line[line.index(after: equals)...]) }
            if let section, !section.isEmpty, key == "model" { models[section] = value(line[line.index(after: equals)...]) }
        }
        return alias.flatMap { models[$0] }.flatMap(modelName)
    }

    /// The same from the JSON config kimi-cli used before `config.toml`.
    static func configuredModel(json: [String: Any]) -> String? {
        guard let alias = json["default_model"] as? String else { return nil }
        return modelName(((json["models"] as? [String: Any])?[alias] as? [String: Any])?["model"])
    }

    /// kimi-cli names a work directory's session folder by the md5 of its path (`<kaos>_<md5>` off the local machine).
    static func workDirFolder(_ path: String, kaos: String?) -> String {
        let hash = Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let kaos, !kaos.isEmpty, kaos != "local" else { return hash }
        return "\(kaos)_\(hash)"
    }
}

/// One Kimi Code agent journal: the main agent (a session row) or a subagent grouped under it.
final class KimiCodeLogReader: TokenLogReader {
    private let tail: LogLineTail
    private let stateURL: URL
    private var stateStamp: String?
    private let sessionID: String
    private let agentID: String
    private let clientName: String?
    private var turn = LogTurnState(inputTools: ["AskUserQuestion"])
    private var cwd: String?
    /// The cwd the agent's profile disclosed, used when `state.json` has none.
    private var boundCwd: String?
    private var title: String?
    private var role: String?
    private var model: String?
    private var effort: String?
    private var context: TokenContextUsage?
    private var measurement: TokenSpeedMeasurement?
    /// The client's own duration of the last completed turn.
    private var turnSeconds: Double?

    /// Record types read whole; every other line is read only for its trailing time (and type when it has no free text).
    private static let parsedTypes: Set<String> = [
        "turn.ended", "llm.request", "usage.record", "interaction.request", "interaction.resolved", "profile.bind", "config.update",
    ]

    init(url: URL) {
        tail = LogLineTail(url: url)
        let agent = url.deletingLastPathComponent()
        agentID = agent.lastPathComponent
        let session = agent.deletingLastPathComponent().deletingLastPathComponent()
        sessionID = session.lastPathComponent
        stateURL = session.appendingPathComponent("state.json")
        clientName = KimiLog.clientName(url)
    }

    private var isSubagent: Bool { agentID != KimiLog.mainAgent }

    func isRecent(at now: Date) -> Bool { turn.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard var reading = turn.reading(source: .kimi, id: id, model: model, cwd: cwd ?? boundCwd, now: now) else { return [] }
        reading.clientName = clientName
        reading.sessionID = sessionID
        if isSubagent {
            reading.isSubagent = true
            reading.parentSessionID = sessionID
            reading.agentID = agentID
            reading.agentRole = role
        } else {
            reading.title = title
        }
        reading.effort = effort
        reading.context = context
        reading.speedMeasurement = measurement
        if reading.lastOutputTokens != nil { reading.lastTurnDurationSeconds = turnSeconds }
        return [reading]
    }

    func read(tailLimit: Int, now: Date) {
        turn.clamp(to: now.addingTimeInterval(5))
        tail.read(tailLimit: tailLimit, reset: {
            turn = LogTurnState(inputTools: ["AskUserQuestion"])
            context = nil
            measurement = nil
            turnSeconds = nil
        }) { consume($0) }
        readState()
    }

    /// `state.json` is rewritten whole on every metadata change (title, agents); read again when its file, size or time changed.
    private func readState() {
        guard let current = KimiLog.stamp(stateURL), current != stateStamp else { return }
        stateStamp = current
        guard let state = KimiLog.object(stateURL) else { return }
        cwd = LogFields.text(state["cwd"]) ?? LogFields.text(state["workDir"]) ?? cwd
        title = KimiLog.title(state)
        let agent = (state["agents"] as? [String: Any])?[agentID] as? [String: Any]
        role = TokenLogParser.label((agent?["labels"] as? [String: Any])?["profileName"]) ?? role
    }

    private func consume(_ data: Data) {
        var type = KimiLog.sniff(data, KimiLog.typeKey, within: 64, leading: true)
        var event = type == "context.append_loop_event" ? KimiLog.sniff(data, KimiLog.eventKey, within: 256) : nil
        var toolCall = event == "tool.result" ? KimiLog.sniff(data, KimiLog.toolCallKey, within: 512) : nil
        var at = KimiLog.trailingTime(data)
        var record: [String: Any]?
        let light = type == "turn.prompt" || type == "turn.steer" || event == "content.part" || event == "step.begin"
            || (event == "tool.result" && toolCall != nil)
            || (type != nil && type != "context.append_loop_event" && !Self.parsedTypes.contains(type!))
        if !light || at == nil {
            guard let object = LogFields.object(data), let name = object["type"] as? String else { return }
            record = object
            type = name
            at = LogFields.milliseconds(object["time"]) ?? at
            let loop = object["event"] as? [String: Any]
            event = loop?["type"] as? String
            toolCall = LogFields.text(loop?["toolCallId"])
        }
        turn.logged(at)
        let loop = record?["event"] as? [String: Any]
        switch type {
        case "turn.prompt": turn.begin(at: at)
        case "turn.steer": turn.resume(at: at)
        case "turn.ended":
            // Nothing read before it: the turn began before the tail.
            if !turn.turnOpen, turn.lastActivity == nil { turn.resume(at: at) }
            guard turn.turnOpen else { break }
            if record?["reason"] as? String == "completed" {
                turn.close(.complete, at: at, model: model)
                turnSeconds = LogFields.count(record?["durationMs"]).map { Double($0) / 1_000 }
            } else {
                turn.close(.interrupted, at: at, model: model)
            }
        case "context.append_loop_event":
            switch event {
            case "step.begin", "content.part":
                turn.resume(at: at)
                turn.setState(turn.hasPendingTools ? .tool : .working, at: at)
            case "tool.call":
                guard let id = LogFields.text(loop?["toolCallId"]) else { break }
                turn.resume(at: at)
                turn.startTool(id, name: TokenLogParser.label(loop?["name"]), at: at)
            case "tool.result":
                if let toolCall { turn.finishTool(toolCall, at: at) }
            case "step.end":
                turn.touch(at)
                measure(loop, at: at)
            default: break
            }
        case "llm.request":
            // A compaction request (also run by /compact between turns) neither opens a turn nor names the session's model.
            guard record?["kind"] as? String != "compaction" else { break }
            turn.resume(at: at)
            turn.setState(turn.hasPendingTools ? .tool : .working, at: at)
            model = KimiLog.modelName(record?["model"]) ?? model
            if let level = TokenLogParser.label(record?["thinkingEffort"]) { effort = level == "off" ? nil : level }
        case "usage.record":
            // `session`-scoped records are bookkeeping outside a turn (compaction, titles); Kimi Code's own totals skip them.
            guard record?["usageScope"] as? String == "turn", let usage = record?["usage"] as? [String: Any] else { break }
            if turn.lastActivity == nil { turn.resume(at: at) }
            turn.addOutput(LogFields.count(usage["output"]) ?? 0, at: at)
            let used = ["inputOther", "inputCacheRead", "inputCacheCreation"].compactMap { LogFields.count(usage[$0]) }.reduce(0, +)
            if used > 0, let at { context = TokenContextUsage(usedTokens: used, windowTokens: nil, recordedAt: at) }
        case "interaction.request":
            guard let id = LogFields.text(record?["id"]), ["approval", "question"].contains(record?["kind"] as? String ?? "") else { break }
            turn.resume(at: at)
            turn.startRequest(id, at: at)
        case "interaction.resolved":
            if let id = LogFields.text(record?["id"]) { turn.finishRequest(id) }
        case "profile.bind", "config.update":
            boundCwd = LogFields.text((record?["environmentDisclosure"] as? [String: Any])?["cwd"]) ?? boundCwd
            if isSubagent { role = TokenLogParser.label(record?["profileName"]) ?? role }
        default: break
        }
    }

    /// The client's own timing of one model call: output over first-token latency plus streaming time.
    private func measure(_ step: [String: Any]?, at: Date?) {
        guard let step, let at, !["interrupted", "error", "cancelled"].contains(step["finishReason"] as? String ?? ""),
              let output = LogFields.count((step["usage"] as? [String: Any])?["output"]), output > 0,
              let firstToken = KimiLog.duration(step["llmFirstTokenLatencyMs"]),
              let streaming = KimiLog.duration(step["llmStreamDurationMs"]), firstToken + streaming > 0 else { return }
        var speed = TokenSpeedMeasurement(TelemetryReading(provider: .kimi, at: at))
        speed.model = model
        speed.outputTokens = output
        speed.requestDurationMs = firstToken + streaming
        speed.ttftMs = firstToken
        measurement = speed
    }
}

/// One archived kimi-cli journal: a session or one of its subagents.
final class KimiCLILogReader: TokenLogReader {
    private let tail: LogLineTail
    private let sessionID: String
    private let agentID: String?
    private let group: String
    private let shareDir: URL
    private let metaURL: URL?
    private var turn = LogTurnState()
    private var cwd: String?
    private var role: String?
    private var agentModel: String?
    private var configModel: String?
    private var context: TokenContextUsage?
    /// `StatusUpdate`s already counted in the current step, by `message_id`: a step makes one model call, and some
    /// OpenAI-compatible gateways reuse one response id for every call, so ids are only compared within a step.
    private var counted = Set<String>()
    /// Open `QuestionRequest`s by tool call; its tool result answers it.
    private var questions: [String: String] = [:]
    private var workDirsStamp: String?
    private var configStamp: String?
    private var metaStamp: String?

    init(url: URL) {
        tail = LogLineTail(url: url)
        let folder = url.deletingLastPathComponent()
        let session: URL
        if folder.deletingLastPathComponent().lastPathComponent == "subagents" {
            session = folder.deletingLastPathComponent().deletingLastPathComponent()
            agentID = folder.lastPathComponent
            metaURL = folder.appendingPathComponent("meta.json")
        } else {
            session = folder
            agentID = nil
            metaURL = nil
        }
        sessionID = session.lastPathComponent
        group = session.deletingLastPathComponent().lastPathComponent
        shareDir = session.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func isRecent(at now: Date) -> Bool { turn.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard var reading = turn.reading(source: .kimi, id: id, model: agentModel ?? configModel, cwd: cwd, now: now) else { return [] }
        reading.clientName = "Kimi CLI"
        reading.sessionID = sessionID
        if let agentID {
            reading.isSubagent = true
            reading.parentSessionID = sessionID
            reading.agentID = agentID
            reading.agentRole = role
        }
        reading.context = context
        return [reading]
    }

    func read(tailLimit: Int, now: Date) {
        turn.clamp(to: now.addingTimeInterval(5))
        tail.read(tailLimit: tailLimit, reset: {
            turn = LogTurnState()
            context = nil
            counted.removeAll()
            questions.removeAll()
        }) { consume($0) }
        if cwd == nil { readWorkDirs() }
        readConfig()
        readMeta()
    }

    /// `kimi.json` lists every work directory; the one whose md5 names this session's folder is the project.
    private func readWorkDirs() {
        let url = shareDir.appendingPathComponent("kimi.json")
        guard let current = KimiLog.stamp(url), current != workDirsStamp else { return }
        workDirsStamp = current
        for entry in (KimiLog.object(url)?["work_dirs"] as? [[String: Any]]) ?? [] {
            guard let path = LogFields.text(entry["path"]),
                  KimiLog.workDirFolder(path, kaos: entry["kaos"] as? String) == group else { continue }
            cwd = path
            return
        }
    }

    private func readConfig() {
        let toml = shareDir.appendingPathComponent("config.toml")
        let url = FileManager.default.fileExists(atPath: toml.path) ? toml : shareDir.appendingPathComponent("config.json")
        guard let current = KimiLog.stamp(url), current != configStamp else { return }
        configStamp = current
        if url == toml {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_048_576,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            configModel = KimiLog.configuredModel(toml: text)
        } else {
            configModel = KimiLog.object(url, limit: 1_048_576).flatMap(KimiLog.configuredModel(json:))
        }
    }

    /// A subagent's `meta.json`: its type and the model it ran on.
    private func readMeta() {
        guard let metaURL, let current = KimiLog.stamp(metaURL), current != metaStamp else { return }
        metaStamp = current
        guard let meta = KimiLog.object(metaURL, limit: 1_048_576) else { return }
        role = TokenLogParser.label(meta["subagent_type"]) ?? role
        agentModel = KimiLog.modelName((meta["launch_spec"] as? [String: Any])?["effective_model"]) ?? agentModel
    }

    private func consume(_ data: Data) {
        // Streamed content is the bulk of the journal; it only shows the turn is still writing.
        let sniffed = KimiLog.sniff(data, KimiLog.messageTypeKey, within: 96)
        if sniffed == "ContentPart" || sniffed == "ToolCallPart", let at = KimiLog.leadingSeconds(data) {
            turn.logged(at)
            turn.resume(at: at)
            turn.setState(turn.hasPendingTools ? .tool : .working, at: at)
            return
        }
        guard let record = LogFields.object(data), let message = record["message"] as? [String: Any],
              let type = message["type"] as? String else { return }
        let at = TokenLogParser.date(record["timestamp"])
        turn.logged(at)
        let payload = message["payload"] as? [String: Any]
        switch type {
        case "TurnBegin":
            counted.removeAll()
            turn.begin(at: at)
        case "SteerInput": turn.resume(at: at)
        case "StepBegin", "ContentPart", "ToolCallPart":
            if type == "StepBegin" { counted.removeAll() }
            turn.resume(at: at)
            turn.setState(turn.hasPendingTools ? .tool : .working, at: at)
        case "ToolCall":
            guard let id = LogFields.text(payload?["id"]) else { break }
            turn.resume(at: at)
            turn.startTool(id, name: TokenLogParser.label((payload?["function"] as? [String: Any])?["name"]), at: at)
        case "ToolResult":
            guard let id = LogFields.text(payload?["tool_call_id"]) else { break }
            turn.finishTool(id, at: at)
            if let request = questions.removeValue(forKey: id) { turn.finishRequest(request) }
        case "ApprovalRequest", "QuestionRequest":
            guard let id = LogFields.text(payload?["id"]) else { break }
            turn.resume(at: at)
            turn.startRequest(id, at: at)
            if type == "QuestionRequest", let call = LogFields.text(payload?["tool_call_id"]) { questions[call] = id }
        case "ApprovalResponse", "ApprovalRequestResolved":
            if let id = LogFields.text(payload?["request_id"]) { turn.finishRequest(id) }
        case "StatusUpdate":
            if let used = LogFields.count(payload?["context_tokens"]), used > 0, let at {
                context = TokenContextUsage(usedTokens: used, windowTokens: LogFields.count(payload?["max_context_tokens"]).flatMap { $0 > 0 ? $0 : nil },
                                            recordedAt: at)
            }
            guard let usage = payload?["token_usage"] as? [String: Any], let output = LogFields.count(usage["output"]) else { break }
            if let id = LogFields.text(payload?["message_id"]) {
                guard counted.insert(id).inserted else { break }
                if counted.count > 1_024 { counted.removeAll() }
            }
            if turn.lastActivity == nil { turn.resume(at: at) }
            turn.addOutput(output, at: at)
        case "StepInterrupted": turn.close(.interrupted, at: at, model: agentModel ?? configModel)
        case "TurnEnd": turn.close(.complete, at: at, model: agentModel ?? configModel)
        default: break
        }
    }
}
