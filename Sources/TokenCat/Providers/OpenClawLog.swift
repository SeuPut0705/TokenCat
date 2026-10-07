import Foundation

/// OpenClaw (and its earlier names Clawdbot and Moltbot) keeps every agent under `<state dir>/agents/<agentId>/`, in one of
/// two generations (openclaw/openclaw `src/state/openclaw-agent-schema.sql`, `src/agents/sessions/session-manager.ts`):
/// - SQLite (v2026.8.1 on): `agent/openclaw-agent.sqlite`, one reader per database (`OpenClawDatabaseLog`). Sessions are
///   `session_windows` rows (one per transcript generation of a `session_nodes` key); `transcript_events` holds each
///   session's Pi-format entries by `seq`. Since agent schema 23 (v2026.9.6) an entry of 1 KiB or more is usually stored as
///   a zstd frame (`event_zstd`) with uncompressed `navigation_json` facts; macOS and .NET have no zstd decoder, so such a
///   row is read from those facts alone: kind, role, times, provider and model, stop reason, tool call ids and names — not
///   its usage.
/// - JSONL (before v2026.8.1): `sessions/<sessionId>.jsonl` with a `sessions.json` index (`OpenClawLogReader`).
/// Both carry the same entries: a `session` header (`id`, `cwd`), `message` entries `{timestamp, message: {role,
/// timestamp, provider, model, api, usage{input, output, cacheRead, cacheWrite}, stopReason, endTurn, content[toolCall
/// {id, name}]}}`, `toolResult` messages with `toolCallId`, and `model_change` / `custom` `model-snapshot` records.
/// - Turn: the person's message opens it; an assistant reply with tool calls waits on them (`ask_user` waits for the
///   person); `stopReason` `stop` (unless `endTurn: false`) or `length` completes it, `aborted` or `error` interrupts it.
///   Assistant rows OpenClaw writes as transcript bookkeeping (`api: openclaw-transcript`, provider `openclaw` with model
///   `delivery-mirror` / `gateway-injected`, a delivery-mirror marker) are not model output and are skipped
///   (`src/shared/transcript-only-openclaw-assistant.ts`).
/// - Tokens: each readable reply's `usage.output` at its log time. A turn holding a reply whose usage is unreadable (a
///   compressed row) or that mirrors a Codex app-server turn (`idempotencyKey` `codex-app-server:…`, which carries only
///   the last response's usage) has no whole count until the session entry's `outputTokens` — the client's own total for
///   the run it wrote after the run ended — settles it; the rest of that total is logged at the entry's write time.
/// - Session entry (`session_nodes.entry_json` / `sessions.json`): `label` (a rename) or `displayName` (a generated or
///   channel title) as the title, `spawnedBy` / `spawnedBySessionId` for subagents (named by their spawn `label`), `model`,
///   and a fresh `totalTokens` with its `contextTokens` window as context. No request duration is recorded, so no speed.
extension TokenLogFormat {
    static let openclaw = TokenLogFormat(files: { roots, discovery in
        var databases: [URL] = []
        var transcripts: [URL] = []
        for agent in roots.flatMap(discovery.children) where discovery.isFolder(agent) {
            let database = agent.appendingPathComponent("agent").appendingPathComponent(OpenClawLog.databaseName)
            if FileManager.default.fileExists(atPath: database.path) { databases.append(database) }
            transcripts += discovery.children(agent.appendingPathComponent("sessions")).filter { $0.pathExtension == "jsonl" }
        }
        return discovery.recent(databases) + discovery.recent(transcripts)
    }, isLog: OpenClawLog.isLog, open: { url -> TokenLogReader in
        url.lastPathComponent == OpenClawLog.databaseName ? OpenClawDatabaseLog(url: url) : OpenClawLogReader(url: url)
    })
}

enum OpenClawLog {
    static let databaseName = "openclaw-agent.sqlite"

    /// `<agents>/<agentId>/agent/openclaw-agent.sqlite` or `<agents>/<agentId>/sessions/<session>.jsonl`. Archives
    /// (`.jsonl.reset.<time>`, `cold/*.jsonl.zst`), the doctor's import archive and Codex homes are never logs.
    static func isLog(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[parts.count - 4] == "agents" else { return false }
        if parts[parts.count - 1] == databaseName { return parts[parts.count - 2] == "agent" }
        return path.hasSuffix(".jsonl") && parts[parts.count - 2] == "sessions"
    }

    /// OpenClaw's tool names (`docs/tools`); anything else falls back to the shared table.
    static func category(_ name: String) -> ToolCategory {
        switch name {
        case "exec", "process", "bash", "code_execution", "terminal": return .command
        case "read", "write", "edit", "apply_patch": return .file
        case "web_search", "web_fetch", "x_search", "browser": return .web
        case "sessions_spawn", "sessions_send", "subagents", "agents_list", "agents_wait": return .agent
        case "ask_user": return .question
        default: return TokenLogParser.category(name)
        }
    }
}

/// One transcript entry reduced to what TokenCat keeps: kind, role, times, model, stop reason, usage counts, tool call ids
/// and names. Built from a JSONL line or from one `transcript_events` row's SQL projection; never text.
struct OpenClawEvent {
    var type: String?
    /// The entry's `timestamp`, else the row's `created_at`.
    var at: Date?
    var role: String?
    /// `message.timestamp`: when an assistant reply's request started.
    var startedAt: Date?
    var provider: String?
    var model: String?
    var api: String?
    var mirrorKind: String?
    var stopReason: String?
    var endTurn: Bool?
    /// Nil when the reply's usage could not be read.
    var output: Int?
    var context = 0
    var toolCalls: [(id: String, name: String?)] = []
    var toolCallID: String?
    var codexMirror = false
    var sessionID: String?
    var cwd: String?
    /// `model_change.modelId` or a `model-snapshot`'s `data.modelId`.
    var modelChange: String?

    init() {}

    init(record: [String: Any]) {
        type = record["type"] as? String
        at = LogFields.date(record["timestamp"])
        switch type {
        case "session":
            sessionID = LogFields.text(record["id"])
            cwd = (record["cwd"] as? String).flatMap { $0.isEmpty || $0.count > 4_096 ? nil : $0 }
        case "model_change": modelChange = LogFields.text(record["modelId"])
        case "custom" where record["customType"] as? String == "model-snapshot":
            modelChange = LogFields.text((record["data"] as? [String: Any])?["modelId"])
        case "message":
            guard let message = record["message"] as? [String: Any] else { return }
            role = message["role"] as? String
            startedAt = LogFields.milliseconds(message["timestamp"])
            if at == nil { at = startedAt }
            toolCallID = LogFields.text(message["toolCallId"])
            guard role == "assistant" else { return }
            provider = LogFields.text(message["provider"])
            model = LogFields.text(message["model"])
            api = LogFields.text(message["api"])
            mirrorKind = (message["openclawDeliveryMirror"] as? [String: Any]).flatMap { LogFields.text($0["kind"]) }
            stopReason = message["stopReason"] as? String
            endTurn = message["endTurn"] as? Bool
            codexMirror = (message["idempotencyKey"] as? String)?.hasPrefix("codex-app-server:") == true
            let usage = message["usage"] as? [String: Any]
            output = LogFields.count(usage?["output"]) ?? 0
            context = ["input", "cacheRead", "cacheWrite"].compactMap { LogFields.count(usage?[$0]) }.reduce(0, +)
            for block in message["content"] as? [[String: Any]] ?? [] where Self.callTypes.contains(block["type"] as? String ?? "") {
                if let id = LogFields.text(block["id"]) { toolCalls.append((id, TokenLogParser.label(block["name"]))) }
            }
        default: return
        }
    }

    static let callTypes: Set<String> = ["toolCall", "toolUse", "functionCall"]

    /// A reply OpenClaw wrote itself as transcript bookkeeping, not model output.
    var isArtifact: Bool {
        api == "openclaw-transcript"
            || (provider == "openclaw" && (model == "delivery-mirror" || model == "gateway-injected"))
            || ["channel-final", "channel-final-suppressed", "message-tool-source-reply", "cron-direct-delivery-context"]
                .contains(mirrorKind ?? "")
    }
}

/// What a session entry (`session_nodes.entry_json`, `sessions.json`) adds: client titles, subagent identity, the run's
/// output total and the context snapshot. Only these fields are read.
struct OpenClawSessionFacts: Equatable {
    var updatedAt: Date?
    var title: String?
    var isSubagent = false
    var parentSessionID: String?
    var role: String?
    var outputTokens: Int?
    var contextUsed: Int?
    var contextWindow: Int?
    var model: String?
    var workspace: String?

    /// `label` (a rename, or a subagent's spawn label) wins over `displayName`. `totalTokens` counts as context only while
    /// `totalTokensFresh`; `contextTokens` is the window only when OpenClaw took it from the runtime or its versioned
    /// resolution (`resolved` is its own legacy guess).
    init(key: String?, label: Any?, displayName: Any?, spawnedBy: Any?, parentSessionID: String?, updatedAt: Date?,
         outputTokens: Any?, totalTokens: Any?, fresh: Bool, contextTokens: Any?, contextSource: Any?, model: Any?, workspace: Any?) {
        self.updatedAt = updatedAt
        title = SessionTitle.clean(label) ?? SessionTitle.clean(displayName)
        isSubagent = LogFields.text(spawnedBy) != nil || key?.contains(":subagent:") == true
        self.parentSessionID = isSubagent ? parentSessionID : nil
        role = isSubagent ? TokenLogParser.label(label) : nil
        self.outputTokens = LogFields.count(outputTokens)
        contextUsed = fresh ? LogFields.count(totalTokens) : nil
        let source = contextSource as? String
        contextWindow = ["runtime", "runtime-configured", "resolved-v1"].contains(source ?? "") ? LogFields.count(contextTokens) : nil
        self.model = (model as? String).flatMap { $0.isEmpty || $0.count > 128 ? nil : $0 }
        self.workspace = (workspace as? String).flatMap { $0.isEmpty || $0.count > 4_096 ? nil : $0 }
    }
}

/// One session's turn state, fed the same events from either generation.
final class OpenClawTurn {
    private(set) var turn = LogTurnState(inputTools: ["ask_user"])
    private(set) var sessionID: String?
    private(set) var cwd: String?
    private var model: String?
    private var modelChange: String?
    private var context: TokenContextUsage?
    private var sawContent = false
    /// Readable output of the open turn, and whether one of its replies was not readable.
    private var turnKnown = 0
    private var turnUnknown = false
    /// The newest completed turn; `settled` is the entry's total for a turn whose output was not whole.
    private var completed: (at: Date, unknown: Bool, known: Int, settled: Int?)?

    var isOpen: Bool { turn.turnOpen }

    /// The header a skipped head would lose: identity only.
    func identify(_ event: OpenClawEvent) {
        guard event.type == "session" else { return }
        sessionID = sessionID ?? event.sessionID
        cwd = cwd ?? event.cwd
    }

    func consume(_ event: OpenClawEvent, headSkipped: Bool) {
        turn.logged(event.at)
        switch event.type {
        case "session":
            sessionID = event.sessionID ?? sessionID
            cwd = event.cwd ?? cwd
        case "model_change", "custom": modelChange = event.modelChange ?? modelChange
        case "message": message(event, unseenStart: headSkipped && !sawContent)
        default: return
        }
    }

    private func message(_ event: OpenClawEvent, unseenStart: Bool) {
        guard let at = event.at else { return }
        switch event.role {
        case "user":
            sawContent = true
            // A message steering a running turn joins it.
            if turn.turnOpen { turn.setState(.working, at: at) } else { open(at: at, whole: true) }
        case "assistant":
            guard !event.isArtifact else { return }
            sawContent = true
            if !turn.turnOpen { open(at: unseenStart ? nil : event.startedAt ?? at, whole: !unseenStart) }
            if let name = event.model, name.count <= 128 { model = name }
            if let output = event.output {
                turnKnown += output
                turn.addOutput(output, at: at)
            } else {
                turnUnknown = true
            }
            if event.codexMirror { turnUnknown = true }
            if event.context > 0 { context = TokenContextUsage(usedTokens: event.context, windowTokens: nil, recordedAt: at) }
            for call in event.toolCalls { turn.startTool(call.id, name: call.name, at: at) }
            if (event.stopReason == "stop" && event.endTurn != false) || event.stopReason == "length" {
                turn.close(.complete, at: at, model: model)
                completed = (at, turnUnknown, turnKnown, nil)
            } else if event.stopReason == "aborted" || event.stopReason == "error" {
                turn.close(.interrupted, at: at, model: model)
            } else {
                turn.setState(turn.hasPendingTools ? .tool : .working, at: at)
            }
        case "toolResult":
            sawContent = true
            if !turn.turnOpen { open(at: unseenStart ? nil : at, whole: !unseenStart) }
            if let id = event.toolCallID { turn.finishTool(id, at: at) }
            turn.setState(turn.hasPendingTools ? .tool : .working, at: at)
        default:
            return
        }
    }

    private func open(at date: Date?, whole: Bool) {
        turn.begin(at: date, whole: whole)
        turnKnown = 0
        turnUnknown = false
    }

    /// The entry's `outputTokens`, written once a run ended, settles the newest completed turn when its output was not whole
    /// and nothing happened since. The part not already read is logged at the entry's write time.
    func settle(_ facts: OpenClawSessionFacts?) {
        guard var last = completed, last.unknown, last.settled == nil, !turn.turnOpen,
              let total = facts?.outputTokens, let written = facts?.updatedAt, written >= last.at, total >= last.known else { return }
        last.settled = total
        completed = last
        turn.logged(written)
        turn.addOutput(total - last.known, at: written)
    }

    func reading(id: String, facts: OpenClawSessionFacts?, fallbackModel: String?, now: Date) -> TokenReading? {
        guard var reading = turn.reading(source: .openclaw, id: id, model: model ?? modelChange ?? facts?.model ?? fallbackModel,
                                         cwd: cwd ?? facts?.workspace, now: now) else { return nil }
        if let tool = turn.runningTool { reading.toolCategory = tool.name.map(OpenClawLog.category) ?? .other }
        if turn.turnOpen, turnUnknown { reading.currentTurnOutputTokens = nil }
        if let last = completed, last.unknown {
            reading.lastOutputTokens = last.settled.flatMap { $0 > 0 ? $0 : nil }
            reading.measurementAt = reading.lastOutputTokens == nil ? reading.lastActivity : last.at
        }
        reading.sessionID = sessionID
        var usage = context
        if let used = facts?.contextUsed, used > 0, let at = facts?.updatedAt, at > usage?.recordedAt ?? .distantPast {
            usage = TokenContextUsage(usedTokens: used, windowTokens: nil, recordedAt: at)
        }
        usage?.windowTokens = facts?.contextWindow
        reading.context = usage
        if let facts {
            if facts.isSubagent {
                reading.isSubagent = true
                reading.parentSessionID = facts.parentSessionID
                reading.agentID = sessionID
                reading.agentRole = facts.role
            } else {
                reading.title = facts.title
            }
        }
        return reading
    }
}

// MARK: - JSONL (before v2026.8.1)

/// One `sessions/<sessionId>.jsonl` transcript, appended entry by entry; its `sessions.json` entry adds titles and subagent
/// identity.
final class OpenClawLogReader: TokenLogReader {
    private let tail: LogLineTail
    private var state = OpenClawTurn()
    private var headerRead = false
    private var facts: OpenClawSessionFacts?

    init(url: URL) { tail = LogLineTail(url: url) }

    func read(tailLimit: Int, now: Date) {
        state.turn.clamp(to: now.addingTimeInterval(5))
        tail.read(tailLimit: tailLimit, reset: {
            state = OpenClawTurn()
            headerRead = false
        }, line: { line in
            guard let record = LogFields.object(line) else { return }
            state.consume(OpenClawEvent(record: record), headSkipped: tail.skippedHead)
        })
        if tail.skippedHead, !headerRead {
            headerRead = true
            if let line = tail.firstLine(), let record = LogFields.object(line) { state.identify(OpenClawEvent(record: record)) }
        }
        facts = OpenClawSessionIndex.facts(for: tail.url)
        state.settle(facts)
    }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard var reading = state.reading(id: id, facts: facts, fallbackModel: nil, now: now) else { return [] }
        reading.sessionID = reading.sessionID ?? Self.sessionID(tail.url)
        if reading.isSubagent { reading.agentID = reading.sessionID }
        return [reading]
    }

    func isRecent(at now: Date) -> Bool { state.turn.isRecent(at: now) }

    /// `<sessionId>.jsonl`, or a thread's `<sessionId>-topic-<thread>.jsonl`.
    static func sessionID(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// The legacy `sessions.json` index beside the transcripts: `{"<sessionKey>": {sessionId, sessionFile, updatedAt, label,
/// displayName, spawnedBy, …}}`. Read again only when the file changes, at most 16 MB; one per file, shared by the agent's
/// readers (any tracker may ask, so the cache is locked as `CodexThreadNames` is).
enum OpenClawSessionIndex {
    private static let lock = NSLock()
    private static var cache: [String: (stamp: String, facts: [String: OpenClawSessionFacts])] = [:]

    static func facts(for transcript: URL) -> OpenClawSessionFacts? {
        let index = transcript.deletingLastPathComponent().appendingPathComponent("sessions.json")
        lock.lock()
        defer { lock.unlock() }
        var info = stat()
        guard stat(index.path, &info) == 0 else {
            cache[index.path] = nil
            return nil
        }
        let stamp = "\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        if let cached = cache[index.path], cached.stamp == stamp { return cached.facts[transcript.lastPathComponent] }
        var facts: [String: OpenClawSessionFacts] = [:]
        if info.st_size <= 16_777_216, let data = try? Data(contentsOf: index), let entries = LogFields.object(data) {
            let ids = entries.compactMapValues { ($0 as? [String: Any]).flatMap { LogFields.text($0["sessionId"]) } }
            for (key, value) in entries {
                guard let entry = value as? [String: Any], let id = LogFields.text(entry["sessionId"]) else { continue }
                let spawnedBy = LogFields.text(entry["spawnedBy"])
                let fact = OpenClawSessionFacts(
                    key: key, label: entry["label"], displayName: entry["displayName"], spawnedBy: spawnedBy,
                    parentSessionID: LogFields.text(entry["spawnedBySessionId"]) ?? spawnedBy.flatMap { ids[$0] },
                    updatedAt: LogFields.milliseconds(entry["updatedAt"]), outputTokens: entry["outputTokens"],
                    totalTokens: entry["totalTokens"], fresh: entry["totalTokensFresh"] as? Bool == true,
                    contextTokens: entry["contextTokens"], contextSource: entry["contextTokensSource"], model: entry["model"],
                    workspace: entry["spawnedWorkspaceDir"])
                let file = (LogFields.text(entry["sessionFile"]).map { URL(fileURLWithPath: $0).lastPathComponent }) ?? "\(id).jsonl"
                // A key's newest entry wins when two name one file.
                if let existing = facts[file], (existing.updatedAt ?? .distantPast) > (fact.updatedAt ?? .distantPast) { continue }
                facts[file] = fact
            }
        }
        cache[index.path] = (stamp, facts)
        return facts[transcript.lastPathComponent]
    }
}

// MARK: - SQLite (v2026.8.1 on)

/// Reads one agent's `openclaw-agent.sqlite`, opened read-only (OpenClaw writes it in WAL mode).
/// - Re-queried only when the database or its WAL changed; then the 64 most recently updated `session_windows`, kept when
///   among the newest 32, updated within the hour or in an open turn. A session's entries are read by `seq`, only past the
///   last one read (the first read takes its newest 256, plus the header for its cwd); its entry facts are read again only
///   when the node's `updated_at` moves. A read the database refused (busy) is never cached.
/// - SQL selects only kinds, roles, times, model, stop reasons, usage counts and tool call ids and names (`json_extract`
///   inside SQLite, from `event_json` or a compressed row's `navigation_json`), so message text never reaches TokenCat.
final class OpenClawDatabaseLog: TokenLogReader {
    let url: URL
    private var signature: [Int64]?
    private var sessions: [String: Session] = [:]

    private final class Session {
        let id: String
        var state = OpenClawTurn()
        var lastSeq: Int64?
        var skippedHead = false
        /// Window `updated_at`, `transcript_updated_at` and the node's `updated_at` at the last refresh.
        var stamp: [Int64?]?
        var nodeUpdated: Int64?
        var facts: OpenClawSessionFacts?
        var windowModel: String?
        var updated = Date.distantPast

        init(id: String) { self.id = id }
    }

    /// Which optional columns this store has: `session_nodes` arrived with agent schema 14, compressed rows with 23.
    private struct Schema {
        var nodes = false
        var transcriptUpdated = false
        var navigation = false

        init?(_ database: OpenCodeDatabase) {
            var windows = Set<String>(), nodes = Set<String>(), events = Set<String>()
            for (table, into) in [("session_windows", 0), ("session_nodes", 1), ("transcript_events", 2)] {
                database.query("SELECT name FROM pragma_table_info('\(table)')") { row in
                    guard let name = row.text(0) else { return }
                    switch into {
                    case 0: windows.insert(name)
                    case 1: nodes.insert(name)
                    default: events.insert(name)
                    }
                }
            }
            guard windows.isSuperset(of: ["session_id", "session_key", "updated_at"]),
                  events.isSuperset(of: ["session_id", "seq", "event_json", "created_at"]) else { return nil }
            self.nodes = nodes.isSuperset(of: ["session_key", "current_session_id", "entry_json", "updated_at"])
            transcriptUpdated = windows.contains("transcript_updated_at")
            navigation = events.contains("navigation_json")
        }
    }

    init(url: URL) { self.url = url }

    func read(tailLimit: Int, now: Date) {
        for session in sessions.values { session.state.turn.clamp(to: now.addingTimeInterval(5)) }
        guard let current = OpenCodeDatabase.signature(url.path), current != signature,
              let database = OpenCodeDatabase(path: url.path) else { return }
        guard database.execute("BEGIN") else { return }
        defer { _ = database.execute("COMMIT") }
        guard let schema = Schema(database) else {
            // A store without sessions (a schema-1 cache database, or one not migrated yet).
            sessions = [:]
            signature = current
            return
        }
        var listed: [(id: String, stamp: [Int64?], node: Int64?)] = []
        let node = schema.nodes ? "n.updated_at" : "NULL"
        let join = schema.nodes ? "LEFT JOIN session_nodes n ON n.session_key = w.session_key AND n.current_session_id = w.session_id" : ""
        let transcript = schema.transcriptUpdated ? "w.transcript_updated_at" : "NULL"
        guard database.query("SELECT w.session_id, w.updated_at, \(transcript), \(node) FROM session_windows w \(join) ORDER BY w.updated_at DESC LIMIT 64",
                             row: { row in
            guard let id = row.text(0) else { return }
            listed.append((id, [row.integer(1), row.integer(2), row.integer(3)], row.integer(3)))
        }) else { return }
        var kept: [String: Session] = [:]
        var complete = true
        for (offset, row) in listed.enumerated() {
            let existing = sessions[row.id]
            let updated = row.stamp.prefix(2).compactMap { $0 }.max().map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? .distantPast
            guard offset < 32 || now.timeIntervalSince(updated) <= 3_600 || existing?.state.isOpen == true else { continue }
            let session = existing ?? Session(id: row.id)
            session.updated = updated
            if session.stamp != row.stamp {
                if refresh(session, node: row.node, schema: schema, database: database) {
                    session.stamp = row.stamp
                } else {
                    // Keeps what was read; a nil stamp makes the next read refresh it again.
                    session.stamp = nil
                    complete = false
                }
            }
            kept[row.id] = session
        }
        sessions = kept
        signature = complete ? current : nil
    }

    /// False when the database refused a read, or a burst filled the batch; what was read stays and the rest is read next.
    private func refresh(_ session: Session, node: Int64?, schema: Schema, database: OpenCodeDatabase) -> Bool {
        if session.stamp == nil || session.nodeUpdated != node {
            guard readFacts(session, schema: schema, database: database) else { return false }
            session.nodeUpdated = node
        }
        var bounds: (low: Int64, high: Int64)?
        guard database.query("SELECT min(seq), max(seq) FROM transcript_events WHERE session_id = ?", [session.id], row: { row in
            if let low = row.integer(0), let high = row.integer(1) { bounds = (low, high) }
        }) else { return false }
        guard let bounds else { return true }
        // A rewind or cut that removed entries: read the session again.
        if let last = session.lastSeq, bounds.high < last {
            session.state = OpenClawTurn()
            session.lastSeq = nil
        }
        let start: Int64
        if let last = session.lastSeq {
            start = last + 1
        } else {
            start = max(bounds.low, bounds.high - 255)
            session.skippedHead = start > bounds.low
            if session.skippedHead, !readHeader(session, low: bounds.low, database: database) { return false }
        }
        guard start <= bounds.high else {
            session.state.settle(session.facts)
            return true
        }
        var events: [(seq: Int64, event: OpenClawEvent)] = []
        guard database.query(Self.eventsQuery(navigation: schema.navigation, start: start), [session.id], row: { row in
            guard let seq = row.integer(0) else { return }
            events.append((seq, Self.event(row)))
        }) else { return false }
        for entry in events {
            session.state.consume(entry.event, headSkipped: session.skippedHead)
            session.lastSeq = entry.seq
        }
        session.state.settle(session.facts)
        return events.count < 2_048
    }

    private func readHeader(_ session: Session, low: Int64, database: OpenCodeDatabase) -> Bool {
        database.query("""
            SELECT json_extract(j, '$.type'), json_extract(j, '$.id'), json_extract(j, '$.cwd')
            FROM (SELECT CASE WHEN json_valid(event_json) THEN event_json END AS j FROM transcript_events WHERE session_id = ? AND seq = \(low))
            """, [session.id]) { row in
            var event = OpenClawEvent()
            event.type = row.text(0)
            event.sessionID = row.text(1)
            event.cwd = row.text(2).flatMap { $0.count > 4_096 ? nil : $0 }
            session.state.identify(event)
        }
    }

    private func readFacts(_ session: Session, schema: Schema, database: OpenCodeDatabase) -> Bool {
        guard schema.nodes else {
            return database.query("SELECT model FROM session_windows WHERE session_id = ?", [session.id]) { session.windowModel = $0.text(0) }
        }
        // The parent: the session id captured at spawn, else the spawning key's current session in this store.
        return database.query("""
            SELECT key, model, updated, substr(json_extract(j, '$.label'), 1, 4096), substr(json_extract(j, '$.displayName'), 1, 4096),
                   json_extract(j, '$.spawnedBy'),
                   coalesce(json_extract(j, '$.spawnedBySessionId'),
                            (SELECT p.current_session_id FROM session_nodes p WHERE p.session_key = json_extract(j, '$.spawnedBy'))),
                   json_extract(j, '$.outputTokens'), json_extract(j, '$.totalTokens'), json_extract(j, '$.totalTokensFresh'),
                   json_extract(j, '$.contextTokens'), json_extract(j, '$.contextTokensSource'), json_extract(j, '$.model'),
                   substr(json_extract(j, '$.spawnedWorkspaceDir'), 1, 4097)
            FROM (SELECT w.session_key AS key, w.model AS model, n.updated_at AS updated,
                         CASE WHEN json_valid(n.entry_json) THEN n.entry_json END AS j
                  FROM session_windows w
                  LEFT JOIN session_nodes n ON n.session_key = w.session_key AND n.current_session_id = w.session_id
                  WHERE w.session_id = ?)
            """, [session.id]) { row in
            session.windowModel = row.text(1)
            session.facts = OpenClawSessionFacts(
                key: row.text(0), label: row.text(3), displayName: row.text(4), spawnedBy: row.text(5), parentSessionID: row.text(6),
                updatedAt: row.date(2), outputTokens: row.integer(7).map { NSNumber(value: $0) }, totalTokens: row.integer(8).map { NSNumber(value: $0) },
                fresh: row.integer(9) == 1, contextTokens: row.integer(10).map { NSNumber(value: $0) }, contextSource: row.text(11),
                model: row.text(12), workspace: row.text(13))
        }
    }

    /// One row per entry from `start`, at most 2,048 per read. A compressed row (`event_json` NULL) answers from its
    /// navigation facts (`$.model…`, the same paths), which hold no usage.
    private static func eventsQuery(navigation: Bool, start: Int64) -> String {
        func field(_ path: String) -> String {
            navigation ? "CASE WHEN j IS NOT NULL THEN json_extract(j, '$\(path)') ELSE json_extract(n, '$.model\(path)') END"
                : "json_extract(j, '$\(path)')"
        }
        let source = navigation
            ? "CASE WHEN event_json IS NULL AND json_valid(navigation_json) THEN navigation_json END AS n"
            : "NULL AS n"
        let contentPath = navigation ? "CASE WHEN j IS NOT NULL THEN '$.message.content' ELSE '$.model.message.content' END" : "'$.message.content'"
        let idempotency = navigation
            ? "coalesce(json_extract(j, '$.message.idempotencyKey'), json_extract(n, '$.navigation.message.idempotencyKey'))"
            : "json_extract(j, '$.message.idempotencyKey')"
        return """
            SELECT seq, created_at, \(field(".type")), \(field(".timestamp")), \(field(".message.role")), \(field(".message.timestamp")),
                   \(field(".message.provider")), \(field(".message.model")), json_extract(j, '$.message.api'),
                   json_extract(j, '$.message.openclawDeliveryMirror.kind'), \(field(".message.stopReason")), json_extract(j, '$.message.endTurn'),
                   json_extract(j, '$.message.usage.output'), json_extract(j, '$.message.usage.input'),
                   json_extract(j, '$.message.usage.cacheRead'), json_extract(j, '$.message.usage.cacheWrite'),
                   \(field(".message.toolCallId")),
                   CASE WHEN \(field(".message.role")) = 'assistant' THEN
                       (SELECT json_group_array(json_array(json_extract(c.value, '$.id'), json_extract(c.value, '$.name')))
                        FROM json_each(coalesce(j, n), \(contentPath)) AS c
                        WHERE CASE WHEN c.type = 'object' THEN json_extract(c.value, '$.type') END IN ('toolCall', 'toolUse', 'functionCall'))
                   END,
                   substr(\(idempotency), 1, 17) = 'codex-app-server:',
                   \(field(".modelId")), \(field(".customType")), json_extract(j, '$.data.modelId'), json_extract(j, '$.id'),
                   substr(json_extract(j, '$.cwd'), 1, 4097), j IS NOT NULL
            FROM (SELECT seq, created_at, CASE WHEN json_valid(event_json) THEN event_json END AS j, \(source)
                  FROM transcript_events WHERE session_id = ? AND seq >= \(start) ORDER BY seq LIMIT 2048)
            """
    }

    /// Columns of `eventsQuery`, in order.
    private static func event(_ row: OpenCodeDatabase.Row) -> OpenClawEvent {
        func count(_ column: Int32) -> Int? { row.integer(column).flatMap { $0 >= 0 && $0 <= Int64(Int32.max) ? Int($0) : nil } }
        var event = OpenClawEvent()
        event.type = row.text(2)
        event.at = LogFields.date(row.text(3)) ?? row.date(1)
        event.role = row.text(4)
        event.startedAt = row.date(5)
        event.toolCallID = row.text(16)
        switch event.type {
        case "session":
            event.sessionID = row.text(22)
            event.cwd = row.text(23).flatMap { $0.isEmpty || $0.count > 4_096 ? nil : $0 }
        case "model_change": event.modelChange = row.text(19)
        case "custom" where row.text(20) == "model-snapshot": event.modelChange = row.text(21)
        default: break
        }
        guard event.role == "assistant" else { return event }
        event.provider = row.text(6)
        event.model = row.text(7)
        event.api = row.text(8)
        event.mirrorKind = row.text(9)
        event.stopReason = row.text(10)
        event.endTurn = row.integer(11).map { $0 != 0 }
        event.codexMirror = row.integer(18) == 1
        // Usage is readable only from an uncompressed row.
        if row.integer(24) == 1 {
            event.output = count(12) ?? 0
            event.context = [count(13), count(14), count(15)].compactMap { $0 }.reduce(0, +)
        }
        if let calls = row.text(17), let list = (try? JSONSerialization.jsonObject(with: Data(calls.utf8))) as? [[Any]] {
            for call in list where call.count == 2 {
                if let id = LogFields.text(call[0]) { event.toolCalls.append((id, TokenLogParser.label(call[1]))) }
            }
        }
        return event
    }

    func isRecent(at now: Date) -> Bool {
        sessions.values.contains { $0.state.isOpen || now.timeIntervalSince($0.updated) <= 3_600 || $0.state.turn.isRecent(at: now) }
    }

    func readings(id: String, now: Date) -> [TokenReading] {
        sessions.values.compactMap { session in
            guard var reading = session.state.reading(id: "\(id)#\(session.id)", facts: session.facts,
                                                      fallbackModel: session.windowModel, now: now) else { return nil }
            reading.sessionID = session.id
            if reading.isSubagent { reading.agentID = session.id }
            return reading
        }
    }
}
