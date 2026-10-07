import Foundation

extension TokenLogFormat {
    /// Goose's `sessions.db` in each data folder's `sessions` (the roots); one reader covers every session in it.
    static let goose = TokenLogFormat(files: { roots, discovery in
        discovery.recent(roots.map { $0.appendingPathComponent(GooseLog.databaseName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) })
    }, isLog: GooseLog.isDatabase, open: { GooseLog(url: $0) })
}

/// Reads Goose sessions from its SQLite store (crates/goose/src/session/session_manager.rs, schema 16), opened read-only
/// (Goose writes it in WAL mode).
/// - Re-queried only when the database or its WAL changed; then the 64 newest sessions by `updated_at`, refreshing those
///   whose `updated_at` moved, with an open turn, or updated within two minutes (`updated_at` has whole seconds). Message
///   content blocks are parsed once per message row; a read the database refused (busy) is never cached.
/// - Only roles, times, visibility, block types, tool names and ids, per-call token counts and durations, model, cwd and a
///   title Goose generated or the person set are read. JSON columns are read through `json_extract`/`json_each`, so message
///   text, tool arguments and results never leave SQLite.
/// - Turn state, as Goose's own `pending_tool_confirmations`: the turn opens at the newest user-visible user message that is
///   no tool response. A tool confirmation or MCP elicitation without its answer waits for the person (`input`); a tool
///   request without its `toolResponse` runs (`tool`); tool results or a fresh prompt are `working`; an assistant reply
///   without tool requests ends the turn (`complete`), an error block (or credits running out) as `interrupted`.
/// - Tokens: `usage_ledger` rows (one per model call, whole-second `created_timestamp`); the backfilled `carried_forward`
///   rows are no call and are skipped. A turn's output is the rows from its prompt to the next one.
/// - Speed: the newest assistant message's own `metadata.usage` — output tokens over `elapsedMs`, the request time Goose's
///   stream wrapper measured (first-token wait included, `timeToFirstTokenMs` kept). Nothing is measured without it.
/// - A session on a CLI or ACP agent provider (claude-code, codex, gemini-cli, cursor-agent, `*-acp`) reports no output or
///   speed: that agent writes its own log, which TokenCat already counts. Its state, tool, model and context still show.
final class GooseLog: TokenLogReader {
    static let databaseName = "sessions.db"
    let url: URL
    private var signature: [Int64]?
    private var sessions: [String: Session] = [:]

    init(url: URL) { self.url = url }

    static func isDatabase(_ path: String) -> Bool { (path as NSString).lastPathComponent == databaseName }

    // MARK: Reading

    func read(tailLimit: Int, now: Date) {
        guard let current = OpenCodeDatabase.signature(url.path), current != signature, let database = OpenCodeDatabase(path: url.path) else { return }
        guard database.execute("BEGIN") else { return }
        defer { _ = database.execute("COMMIT") }
        // Older Goose versions lack later columns (name v3 … parent_session_id v15) and the ledger (v15).
        guard let columns = Self.columns("sessions", database), columns.contains("id"), let messageColumns = Self.columns("messages", database)
        else { return }
        var hasLedger = false
        guard database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_ledger'", row: { _ in hasLedger = true })
        else { return }
        func column(_ name: String, _ expression: String? = nil) -> String { columns.contains(name) ? expression ?? name : "NULL" }
        let config = "CASE WHEN json_valid(model_config_json) THEN model_config_json END"
        let sql = """
            SELECT id, \(column("working_dir")), substr(\(column("name")), 1, 1024), substr(\(column("description")), 1, 1024),
                   \(column("user_set_name")), \(column("session_type")),
                   CAST(strftime('%s', COALESCE(updated_at, created_at)) AS INTEGER), \(column("provider_name")),
                   \(column("model_config_json", "json_extract(\(config), '$.model_name')")),
                   \(column("model_config_json", "json_extract(\(config), '$.context_limit')")),
                   \(column("parent_session_id")), \(column("recipe_json", "recipe_json IS NOT NULL AND recipe_json != ''"))
            FROM sessions \(columns.contains("archived_at") ? "WHERE archived_at IS NULL" : "") ORDER BY 7 DESC LIMIT 64
            """
        var listed: [Listed] = []
        guard database.query(sql, row: { row in
            guard let id = row.text(0), let updated = row.integer(6).flatMap(Self.seconds) else { return }
            let name = row.text(2).flatMap { $0.isEmpty ? nil : $0 } ?? row.text(3)
            listed.append(Listed(id: id, directory: row.text(1),
                                 title: Self.title(name, userSet: row.integer(4) == 1, provider: row.text(7), recipe: row.integer(11) == 1),
                                 updated: updated, model: Self.text(row.text(8)), contextLimit: row.integer(9).map { Int(clamping: $0) },
                                 parentID: Self.text(row.text(10)), agentProvider: row.text(7).map(Self.isAgentProvider) ?? false))
        }) else { return }
        var kept: [String: Session] = [:]
        var complete = true
        for (offset, row) in listed.enumerated() {
            let existing = sessions[row.id]
            guard offset < 32 || now.timeIntervalSince(row.updated) <= 3_600 || existing?.summary.open == true else { continue }
            let session = existing ?? Session(id: row.id)
            let moved = existing == nil || session.updated != row.updated
            session.directory = row.directory
            session.title = row.title
            session.sessionModel = row.model
            session.contextLimit = row.contextLimit.flatMap { $0 > 0 ? $0 : nil }
            session.parentID = row.parentID
            session.agentProvider = row.agentProvider
            session.updated = row.updated
            // A session idle for over an hour reads a shorter window: its last turns, not 200 messages of content.
            let window = session.summary.open || now.timeIntervalSince(row.updated) <= 3_600 ? 200 : 50
            if moved || session.summary.open || now.timeIntervalSince(row.updated) <= 120,
               !refresh(session, database, window: window, metadata: messageColumns.contains("metadata_json"), ledger: hasLedger) {
                // Keeps what was read before; `distantPast` makes the next read refresh it again.
                session.updated = .distantPast
                complete = false
            }
            kept[row.id] = session
        }
        sessions = kept
        signature = complete ? current : nil
    }

    private static func columns(_ table: String, _ database: OpenCodeDatabase) -> Set<String>? {
        var names = Set<String>()
        return database.query("SELECT name FROM pragma_table_info('\(table)')", row: { if let name = $0.text(0) { names.insert(name) } }) ? names : nil
    }

    /// False when the database refused a read; the session then keeps its previous messages.
    private func refresh(_ session: Session, _ database: OpenCodeDatabase, window: Int, metadata: Bool, ledger: Bool) -> Bool {
        // Goose orders messages by (created_timestamp, id); seconds, or milliseconds in some imported rows.
        let created = "CASE WHEN created_timestamp > 10000000000 THEN created_timestamp / 1000 ELSE created_timestamp END"
        var messages: [Message] = []
        guard database.query("""
            SELECT id, role, \(created), CAST(strftime('%s', timestamp) AS INTEGER), json_extract(md, '$.userVisible'),
                   json_extract(md, '$.usage.outputTokens'), json_extract(md, '$.usage.elapsedMs'),
                   json_extract(md, '$.usage.timeToFirstTokenMs'), json_extract(md, '$.inference.resolvedModel'),
                   json_extract(md, '$.inference.requestedModel')
            FROM (SELECT id, role, created_timestamp, timestamp, \(metadata ? "CASE WHEN json_valid(metadata_json) THEN metadata_json END" : "NULL") AS md
                  FROM messages WHERE session_id = ? ORDER BY created_timestamp DESC, id DESC LIMIT \(window))
            """, [session.id], row: { row in
            guard let id = row.integer(0), let created = row.integer(2).flatMap(Self.seconds) else { return }
            var message = Message(id: id, created: created)
            message.role = row.text(1) == "user" ? .user : row.text(1) == "assistant" ? .assistant : .other
            message.written = row.integer(3).flatMap(Self.seconds)
            message.visible = row.integer(4) != 0
            message.output = row.integer(5).map { Int(clamping: max(0, $0)) } ?? 0
            message.elapsedMs = row.double(6).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            message.ttftMs = row.double(7).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            message.model = Self.text(row.text(8)) ?? Self.text(row.text(9))
            messages.append(message)
        }) else { return false }

        let missing = messages.map(\.id).filter { session.blocks[$0] == nil }
        if !missing.isEmpty {
            var fetched = Dictionary(uniqueKeysWithValues: missing.map { ($0, [Block]()) })
            // Only each block's type, ids, tool names and notification kind; `j.type = 'object'` keeps json_extract off
            // bare values.
            guard database.query("""
                SELECT m.id, json_extract(j.value, '$.type'), json_extract(j.value, '$.id'),
                       json_extract(j.value, '$.toolCall.value.name'), json_extract(j.value, '$.toolName'),
                       json_extract(j.value, '$.data.actionType'), json_extract(j.value, '$.data.id'),
                       json_extract(j.value, '$.data.toolName'), json_extract(j.value, '$.notificationType')
                FROM messages m, json_each(CASE WHEN json_valid(m.content_json) THEN m.content_json ELSE '[]' END) j
                WHERE m.id IN (\(missing.map(String.init).joined(separator: ","))) AND j.type = 'object' ORDER BY m.id, j.key
                """, row: { row in
                guard let id = row.integer(0) else { return }
                fetched[id, default: []].append(Block(type: Self.text(row.text(1)), id: Self.text(row.text(2)),
                                                      tool: Self.text(row.text(3)) ?? Self.text(row.text(4)),
                                                      action: Self.text(row.text(5)), actionID: Self.text(row.text(6)),
                                                      actionTool: Self.text(row.text(7)), notification: Self.text(row.text(8))))
            }) else { return false }
            session.blocks.merge(fetched) { _, new in new }
        }
        let ids = Set(messages.map(\.id))
        session.blocks = session.blocks.filter { ids.contains($0.key) }
        session.messages = messages.map { message in
            var message = message
            message.blocks = session.blocks[message.id] ?? []
            return message
        }

        var usage: [Usage] = []
        if ledger {
            guard database.query("""
                SELECT \(created), output_tokens, input_tokens, model, is_compaction FROM usage_ledger
                WHERE session_id = ? AND COALESCE(cost_source, '') != 'carried_forward' ORDER BY id DESC LIMIT 200
                """, [session.id], row: { row in
                guard let at = row.integer(0).flatMap(Self.seconds) else { return }
                usage.append(Usage(at: at, output: row.integer(1).map { Int(clamping: max(0, $0)) } ?? 0,
                                   input: row.integer(2).map { Int(clamping: max(0, $0)) } ?? 0,
                                   model: Self.text(row.text(3)), compaction: (row.integer(4) ?? 0) != 0))
            }) else { return false }
        }
        session.usage = usage
        session.summary = Summary(session)
        return true
    }

    // MARK: Readings

    func isRecent(at now: Date) -> Bool {
        sessions.values.contains { $0.summary.open || $0.summary.lastLogAt.map { now.timeIntervalSince($0) <= 3_600 } == true }
    }

    func readings(id: String, now: Date) -> [TokenReading] {
        sessions.values.compactMap { session -> TokenReading? in
            let summary = session.summary
            guard let lastActivity = summary.lastActivity else { return nil }
            let ceiling = now.addingTimeInterval(5)
            var reading = TokenReading(source: .goose, id: "\(id)#\(session.id)")
            reading.sessionID = session.id
            reading.title = session.title
            if let parent = session.parentID {
                reading.isSubagent = true
                reading.parentSessionID = parent
                reading.agentID = session.id
            }
            if let cwd = session.directory, !cwd.isEmpty, cwd != "." {
                reading.project = URL(fileURLWithPath: cwd).lastPathComponent
                reading.projectPath = cwd
            }
            reading.model = summary.model ?? session.sessionModel
            reading.context = summary.context.map { context in
                var context = context
                context.windowTokens = session.contextLimit
                return context
            }
            reading.lastActivity = min(lastActivity, ceiling)
            let liveAt = min(max(summary.lastLogAt ?? lastActivity, session.updated, lastActivity), ceiling)
            reading.lastLogAt = liveAt
            reading.measurementAt = summary.completion?.at ?? reading.lastActivity
            let age = now.timeIntervalSince(liveAt)
            let horizon: TimeInterval = summary.waitsForInput ? 86_400 : summary.toolName != nil ? 900 : 600
            let active = summary.open && age >= -5 && age <= horizon
            reading.active = active
            if !summary.open { reading.activityState = summary.state }
            else if summary.waitsForInput { reading.activityState = active ? .input : .unfinished }
            else if active { reading.activityState = summary.state }
            else { reading.activityState = age <= 1_800 ? .stale : .unfinished }
            if summary.open, let tool = summary.toolName {
                reading.toolName = tool
                reading.toolCategory = Self.category(tool)
            }
            reading.currentTurnStartedAt = summary.open ? summary.startedAt : nil
            // A CLI or ACP agent provider logs its own tokens (Claude Code, Codex, …), which TokenCat already counts there.
            if !session.agentProvider {
                reading.currentTurnOutputTokens = summary.open ? summary.turnOutput : nil
                reading.lastOutputAt = summary.outputs.last?.at
                reading.lastOutputDelta = summary.outputs.last?.tokens
                reading.recentOutputs = summary.outputs.filter {
                    let age = now.timeIntervalSince($0.at)
                    return age >= -5 && age <= TokenTracker.recentOutputWindow
                }
                reading.lastOutputTokens = summary.completion?.output
                reading.speedMeasurement = summary.speed
            }
            reading.sampledAt = now
            return reading
        }
    }

    /// Goose names an extension's tools `<extension>__<tool>`; the developer and summon extensions' are unprefixed
    /// (`shell`, `write`, `edit`, `tree`, `delegate`), older builds wrote `developer__shell`, `developer__text_editor`.
    static func category(_ name: String) -> ToolCategory {
        let split = name.range(of: "__")
        let owner = split.map { String(name[..<$0.lowerBound]) }
        let tool = split.map { String(name[$0.upperBound...]) } ?? name
        switch owner {
        case nil, "developer":
            switch tool {
            case "shell": return .command
            case "write", "edit", "tree", "text_editor", "read_image": return .file
            case "delegate": return .agent
            default: return .other
            }
        case "summon", "subagent", "dynamic_task": return .agent
        default: return .mcp
        }
    }

    /// Names Goose gives a session before (or instead of) generating one: the ACP "New Chat", `--no-session`'s "CLI Session",
    /// a subagent's "Delegated task", and internal probes.
    static let placeholders: Set<String> = ["New Chat", "CLI Session", "Delegated task", "MCP Probe", "Tool Permission Configuration"]
    /// Providers that run another agent's CLI or ACP server (codex, cursor-agent, and every provider that manages its own
    /// context — claude-code, gemini-cli, the `*-acp` agents). That agent writes its own log, and Goose names the session from
    /// the first prompt's first words (`uses_local_session_naming`).
    static func isAgentProvider(_ provider: String) -> Bool {
        ["codex", "cursor-agent", "claude-code", "gemini-cli"].contains(provider) || provider.hasSuffix("-acp")
    }

    /// The session's `name` (`description` before schema 3) when the person or client set it (`user_set_name`), a recipe
    /// titled it, or the model generated it; never a placeholder or a name cut from the first prompt.
    static func title(_ raw: String?, userSet: Bool, provider: String?, recipe: Bool) -> String? {
        guard let name = SessionTitle.clean(raw) else { return nil }
        if userSet { return name }
        if placeholders.contains(name) { return nil }
        if !recipe, let provider, isAgentProvider(provider) { return nil }
        return name
    }

    fileprivate static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 256 else { return nil }
        return value
    }

    fileprivate static func seconds(_ value: Int64) -> Date? {
        value > 0 && value < 253_402_300_800 ? Date(timeIntervalSince1970: TimeInterval(value)) : nil
    }
}

// MARK: - Model

private struct Listed {
    let id: String
    let directory: String?
    let title: String?
    let updated: Date
    let model: String?
    let contextLimit: Int?
    let parentID: String?
    let agentProvider: Bool
}

private enum Role { case user, assistant, other }

/// One content block's type, ids and tool names; never its text, arguments or result.
private struct Block {
    let type: String?
    let id: String?
    let tool: String?
    let action: String?
    let actionID: String?
    let actionTool: String?
    let notification: String?
}

/// One message's metadata; never its text.
private struct Message {
    let id: Int64
    let created: Date
    var role: Role = .other
    /// The row's insert time (`timestamp`).
    var written: Date?
    var visible = true
    var output = 0
    var elapsedMs: Double?
    var ttftMs: Double?
    var model: String?
    var blocks: [Block] = []

    init(id: Int64, created: Date) {
        self.id = id
        self.created = created
    }

    var at: Date { written ?? created }

    private func has(_ types: Set<String>) -> Bool { blocks.contains { $0.type.map(types.contains) == true } }
    var isToolResponse: Bool { has(["toolResponse"]) }
    /// A prompt from the person, where Goose's `active_turn_messages` starts the turn.
    var opensTurn: Bool { role == .user && visible && !isToolResponse }

    enum Kind { case user, tools, reply, failure, other }
    /// What an assistant message means for the turn; `other` (notices, an action block alone) leaves it as it was.
    var kind: Kind {
        if role == .user { return .user }
        if has(["toolRequest", "frontendToolRequest"]) { return .tools }
        if has(["error"]) || blocks.contains(where: { $0.type == "systemNotification" && $0.notification == "creditsExhausted" }) { return .failure }
        if has(["text", "thinking", "redactedThinking", "image", "document"]) { return .reply }
        return .other
    }
}

private struct Usage {
    let at: Date
    let output: Int
    let input: Int
    let model: String?
    let compaction: Bool
}

private final class Session {
    let id: String
    var directory: String?
    var title: String?
    var sessionModel: String?
    var contextLimit: Int?
    var parentID: String?
    /// The session runs a CLI or ACP agent provider, whose own log TokenCat already reads: no output or speed from here.
    var agentProvider = false
    var updated = Date.distantPast
    /// Newest first, at most 200.
    var messages: [Message] = []
    /// Content blocks by message row, parsed once.
    var blocks: [Int64: [Block]] = [:]
    /// Ledger rows, newest first, at most 200.
    var usage: [Usage] = []
    var summary = Summary()

    init(id: String) { self.id = id }
}

/// What a session's messages and ledger say, apart from the clock.
private struct Summary {
    var open = false
    var state: TokenActivityState = .idle
    var toolName: String?
    var waitsForInput = false
    var startedAt: Date?
    var turnOutput: Int?
    var completion: (output: Int, at: Date)?
    var outputs: [TokenOutputEvent] = []
    var lastActivity: Date?
    var lastLogAt: Date?
    var model: String?
    var context: TokenContextUsage?
    var speed: TokenSpeedMeasurement?

    init() {}

    init(_ session: Session) {
        let ordered = Array(session.messages.reversed())
        let usage = session.usage
        guard !ordered.isEmpty || !usage.isEmpty else { return }
        lastActivity = (ordered.map(\.created) + usage.map(\.at)).max()
        lastLogAt = (ordered.map(\.at) + usage.map(\.at)).max()
        model = session.messages.first { $0.role == .assistant && $0.model != nil }?.model ?? usage.lazy.compactMap(\.model).first
        outputs = usage.filter { $0.output > 0 }.map { TokenOutputEvent(at: $0.at, tokens: $0.output) }.reversed()
        if let latest = usage.first(where: { !$0.compaction && $0.input > 0 }) {
            let compacted = usage.first(where: \.compaction).map(\.at)
            context = TokenContextUsage(usedTokens: latest.input, windowTokens: nil, recordedAt: latest.at,
                                        compactedAt: compacted.flatMap { $0 >= latest.at ? $0 : nil })
        }
        if let measured = session.messages.first(where: { $0.role == .assistant && $0.output > 0 }), let duration = measured.elapsedMs {
            var reading = TelemetryReading(provider: .goose, at: measured.at)
            reading.model = measured.model ?? model
            reading.outputTokens = measured.output
            reading.requestDurationMs = duration
            reading.ttftMs = measured.ttftMs
            speed = TokenSpeedMeasurement(reading)
        }

        /// Ledger output from `start` up to (not including) `end`.
        func output(from start: Date, to end: Date?) -> Int {
            usage.reduce(0) { sum, row in
                row.at >= start && end.map { row.at < $0 } != false ? min(sum + row.output, Int(Int32.max)) : sum
            }
        }
        let openers = ordered.indices.filter { ordered[$0].opensTurn }
        let turnStart = openers.last
        let active = ordered[(turnStart.map { $0 + 1 } ?? 0)...]

        var requests: [(id: String, tool: String?)] = []
        var answered = Set<String>(), confirmations: [(id: String, tool: String?)] = [], confirmed = Set<String>()
        var elicitations: [String] = [], elicited = Set<String>()
        for message in active {
            for block in message.blocks {
                switch block.type {
                case "toolRequest", "frontendToolRequest": if let id = block.id { requests.append((id, block.tool)) }
                case "toolResponse": if let id = block.id { answered.insert(id) }
                case "toolConfirmationRequest": if let id = block.id { confirmations.append((id, block.tool)) }
                case "actionRequired":
                    guard let id = block.actionID else { continue }
                    switch block.action {
                    case "toolConfirmation": confirmations.append((id, block.actionTool))
                    case "toolConfirmationResponse": confirmed.insert(id)
                    case "elicitation": elicitations.append(id)
                    case "elicitationResponse": elicited.insert(id)
                    default: break
                    }
                default: break
                }
            }
        }
        let asking = confirmations.filter { !answered.contains($0.id) && !confirmed.contains($0.id) }
        let running = requests.filter { !answered.contains($0.id) }
        let lastKind = active.last { $0.kind != .other }?.kind
        if !asking.isEmpty || elicitations.contains(where: { !elicited.contains($0) }) {
            open = true
            state = .input
            waitsForInput = true
            toolName = asking.last?.tool ?? running.last?.tool
        } else if let tool = running.last {
            open = true
            state = .tool
            toolName = tool.tool
        } else {
            switch lastKind {
            case .reply: state = .complete
            case .failure: state = .interrupted
            case .tools, .user: open = true; state = .working
            case .other, nil:
                // Nothing after the prompt yet: the model is answering it.
                if turnStart != nil { open = true; state = .working } else { state = .idle }
            }
        }
        if open, let start = turnStart {
            startedAt = ordered[start].created
            turnOutput = output(from: ordered[start].created, to: nil)
        }
        // The newest turn that ended in a reply, fully seen.
        for (position, index) in openers.enumerated().reversed() {
            let end = position + 1 < openers.count ? openers[position + 1] : ordered.count
            guard let last = ordered[(index + 1)..<end].last(where: { $0.kind != .other }), last.kind == .reply else { continue }
            let total = output(from: ordered[index].created, to: end < ordered.count ? ordered[end].created : nil)
            if total > 0 { completion = (total, last.at) }
            break
        }
    }
}
