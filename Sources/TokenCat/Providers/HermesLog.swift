import Foundation

extension TokenLogFormat {
    /// Hermes Agent's SQLite store: `<home>/state.db` and each profile's `<home>/profiles/<name>/state.db`. One reader
    /// covers every session in a store.
    static let hermes = TokenLogFormat(files: { roots, discovery in
        let databases = roots.flatMap { root -> [URL] in
            [root.appendingPathComponent("state.db")]
                + discovery.children(root.appendingPathComponent("profiles")).filter(discovery.isFolder).map { $0.appendingPathComponent("state.db") }
        }
        return discovery.recent(databases.filter { FileManager.default.fileExists(atPath: $0.path) })
    }, isLog: HermesLog.isDatabase, open: { HermesLog(url: $0) })
}

/// Reads Hermes Agent (Nous Research) sessions from `state.db`, opened read-only (Hermes writes it in WAL mode), plus the
/// home's `logs/agent.log` for what the database does not keep.
/// - Re-queried only when the database or its WAL changed: the 64 most recently active, unarchived sessions (the table is
///   small; messages are reached through their `(session_id, id)` index). Only ids, roles, finish reasons, tool call ids and
///   names, times, counters, model, cwd and the generated (`llm`) or renamed (`user`) title are selected; never message
///   content, reasoning, tool arguments or the system prompt. A title Hermes derived from the first prompt (`derived`) is
///   no title. Hidden sessions (kept out of Hermes's sidebar, e.g. kanban workers) are real work and are listed.
/// - Compression: Hermes ends a session with `end_reason = 'compression'` and continues the conversation in a child
///   session. Such a chain is one row named after its first session (`hermes --resume <id>` follows the chain to its
///   tip); the newest segment gives its state. A subagent (`source = 'subagent'` or a `_delegate_from` marker) is its own
///   row under its parent's chain; a branch or a reset child is a top-level row.
/// - Turn: a person's message (not observed group chatter, not hidden compaction scaffolding) opens it; an assistant message
///   with tool calls runs them until their tool results are written; `finish_reason = 'stop'` completes it; another
///   finish interrupts it. Hermes writes the assistant message together with its first tool result, so a tool shows only
///   while later calls of the same batch are outstanding (`clarify` waits for the person). agent.log's `Turn ended` or
///   `API call failed after` lines (tagged `[<session id>]`) end a turn the database left open (a failed request writes
///   no assistant message); a live `session_turn_leases` row keeps the turn active.
/// - Tokens: `sessions.output_tokens` (the provider's output total, reasoning included) grows after every API call. Its
///   growth between reads is logged output at the newest of the session's last message, `last_activity_at` and its last
///   `API call` log line; the first total read is a baseline, unless the session started after this reader's first read.
/// - Model: the main task's newest `session_model_usage` row (it follows `/model`), else `sessions.model`.
/// - Context and speed: agent.log's `API call #N: model=… provider=… in=<prompt> out=<n> … latency=<s>s` line, written
///   on the calling thread whose log records carry the session id (compression re-tags it): `in` is the context in use;
///   `out` over `latency` is the request processing rate (first-response wait included; retries flagged when a retry or
///   failure line for the session came before it). A mixture-of-agents call (`provider=moa`) times advisors too and is
///   not a measurement.
final class HermesLog: TokenLogReader {
    let url: URL
    private let agentLog: LogLineTail
    private var signature: [Int64]?
    private var firstReadAt: Date?
    private var chains: [String: Chain] = [:]
    /// Ancestors looked up by id while finding a chain's first session; only ids still reached are kept.
    private var lineage: [String: Segment] = [:]
    /// Live turn leases: conversation (chain) id → expiry.
    private var leases: [String: Date] = [:]
    private var logSessions: [String: LogSession] = [:]

    init(url: URL) {
        self.url = url
        agentLog = LogLineTail(url: url.deletingLastPathComponent().appendingPathComponent("logs/agent.log"))
    }

    /// `state.db` in a Hermes home (`.hermes`, Windows `hermes`, or `HERMES_HOME`) or in a profile under `profiles`.
    static func isDatabase(_ path: String) -> Bool {
        let file = path as NSString
        guard file.lastPathComponent == "state.db" else { return false }
        let folder = file.deletingLastPathComponent as NSString
        let name = folder.lastPathComponent
        return name == ".hermes" || name == "hermes" || (folder.deletingLastPathComponent as NSString).lastPathComponent == "profiles"
            || folder as String == overrideHome
    }

    private static let overrideHome = ProcessInfo.processInfo.environment.path("HERMES_HOME")?.path

    /// The root Hermes lists profiles under: a `HERMES_HOME` of `<root>/profiles/<name>` names `<root>`.
    static func root(_ home: URL) -> URL {
        home.deletingLastPathComponent().lastPathComponent == "profiles" ? home.deletingLastPathComponent().deletingLastPathComponent() : home
    }

    // MARK: Reading

    func read(tailLimit: Int, now: Date) {
        if firstReadAt == nil { firstReadAt = now }
        let ceiling = now.addingTimeInterval(5)
        for chain in chains.values { chain.turn.clamp(to: ceiling) }
        agentLog.read(tailLimit: tailLimit, reset: {}) { consume($0) }
        if let current = OpenCodeDatabase.signature(url.path), current != signature {
            signature = readDatabase(now: now) ? current : nil
        }
        for chain in chains.values { applyLog(chain, now: now) }
    }

    /// False when the database refused a read; the next read queries it again.
    private func readDatabase(now: Date) -> Bool {
        guard let database = Self.open(url.path), database.execute("BEGIN") else { return false }
        defer { _ = database.execute("COMMIT") }
        var listed: [Segment] = []
        let collect: (OpenCodeDatabase.Row) -> Void = { row in
            guard let id = row.text(0) else { return }
            var segment = Segment(id: id)
            segment.source = row.text(1)
            segment.parent = row.text(2)
            segment.model = Self.name(row.text(3))
            segment.cwd = row.text(4)
            segment.title = SessionTitle.clean(row.text(5))
            segment.startedAt = Self.date(row.double(6))
            segment.endedAt = Self.date(row.double(7))
            segment.endReason = row.text(8)
            segment.lastActivityAt = Self.date(row.double(9))
            segment.output = Self.count(row.integer(10))
            segment.messageCount = Self.count(row.integer(11))
            segment.delegated = row.integer(12) == 1
            segment.branched = row.integer(13) == 1
            listed.append(segment)
        }
        // Pre-provenance rows (NULL title_source) were titled by the model or the person; `derived` copies the prompt.
        let current = """
            SELECT id, source, parent_session_id, model, cwd,
                   CASE WHEN title_source IS NULL OR title_source IN ('llm', 'user') THEN substr(title, 1, 256) END,
                   started_at, ended_at, end_reason, last_activity_at, output_tokens, message_count,
                   CASE WHEN json_valid(model_config) THEN json_extract(model_config, '$._delegate_from') IS NOT NULL ELSE 0 END,
                   CASE WHEN json_valid(model_config) THEN json_extract(model_config, '$._branched_from') IS NOT NULL ELSE 0 END
            FROM sessions WHERE archived = 0
            ORDER BY MAX(started_at, COALESCE(last_activity_at, 0), COALESCE(ended_at, 0)) DESC LIMIT 64
            """
        // Older schemas lack the title provenance, activity stamp and archive flag (or SQLite lacks JSON functions).
        let older = """
            SELECT id, source, parent_session_id, model, cwd, NULL, started_at, ended_at, end_reason, NULL, output_tokens,
                   message_count, 0, 0
            FROM sessions ORDER BY MAX(started_at, COALESCE(ended_at, 0)) DESC LIMIT 64
            """
        guard database.query(current, row: collect) || (listed.isEmpty && database.query(older, row: collect)) else { return false }

        var known = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reached = Set<String>()
        func lookup(_ id: String) -> Segment? {
            if let segment = known[id] { return segment }
            reached.insert(id)
            if let cached = lineage[id] { return cached }
            var found: Segment?
            database.query("""
                SELECT source, parent_session_id, end_reason, started_at,
                       CASE WHEN json_valid(model_config) THEN json_extract(model_config, '$._delegate_from') IS NOT NULL ELSE 0 END,
                       CASE WHEN json_valid(model_config) THEN json_extract(model_config, '$._branched_from') IS NOT NULL ELSE 0 END
                FROM sessions WHERE id = ?
                """, [id]) { row in
                var segment = Segment(id: id)
                segment.source = row.text(0)
                segment.parent = row.text(1)
                segment.endReason = row.text(2)
                segment.startedAt = Self.date(row.double(3))
                segment.delegated = row.integer(4) == 1
                segment.branched = row.integer(5) == 1
                found = segment
            }
            if let found { lineage[id] = found; known[id] = found }
            return found
        }
        /// The first session of the compression chain `id` belongs to.
        func root(of id: String) -> String {
            var current = id
            var seen: Set<String> = [id]
            for _ in 0..<100 {
                guard let segment = lookup(current), segment.continuesParent, let parent = segment.parent, !seen.contains(parent),
                      let previous = lookup(parent), previous.endReason == "compression" else { break }
                seen.insert(parent)
                current = parent
            }
            return current
        }

        var order: [String] = []
        var grouped: [String: [Segment]] = [:]
        for segment in listed {
            let chainID = root(of: segment.id)
            if grouped[chainID] == nil { order.append(chainID) }
            grouped[chainID, default: []].append(segment)
        }
        var kept: [String: Chain] = [:]
        var complete = true
        for (offset, chainID) in order.enumerated() {
            guard let segments = grouped[chainID], let tip = segments.first(where: { $0.endReason != "compression" }) ?? segments.first else { continue }
            let existing = chains[chainID]
            guard offset < 32 || now.timeIntervalSince(tip.activity) <= 3_600 || existing?.turn.turnOpen == true else { continue }
            let first = lookup(chainID) ?? tip
            let chain = existing ?? Chain(root: chainID, fresh: (first.startedAt ?? tip.startedAt).map { $0 > (firstReadAt ?? now) } ?? false)
            chain.spawned = first.spawned
            chain.parent = first.spawned ? first.parent.map(root(of:)) : nil
            chain.segments = segments.map(\.id)
            chain.title = tip.title ?? segments.lazy.compactMap(\.title).first ?? first.title
            chain.cwd = tip.cwd ?? segments.lazy.compactMap(\.cwd).first ?? first.cwd
            chain.sessionModel = tip.model ?? segments.lazy.compactMap(\.model).first
            if !refresh(chain, tip: tip, segments: segments, database, now: now) { complete = false }
            kept[chainID] = chain
        }
        chains = kept
        lineage = lineage.filter { reached.contains($0.key) }

        var live: [String: Date] = [:]
        database.query("SELECT conversation_id, expires_at FROM session_turn_leases") { row in
            if let id = row.text(0), let expires = Self.date(row.double(1)) { live[id] = expires }
        }
        leases = live
        return complete
    }

    /// New messages of the chain's newest segment as turn events, then token growth. False when the database refused a
    /// read; the chain keeps its state and is read again.
    private func refresh(_ chain: Chain, tip: Segment, segments: [Segment], _ database: OpenCodeDatabase, now: Date) -> Bool {
        if tip.stamp != chain.stamp || tip.id != chain.tip {
            var model: String?
            database.query("SELECT model FROM session_model_usage WHERE session_id = ? AND task = '' ORDER BY last_seen DESC LIMIT 1",
                           [tip.id]) { model = Self.name($0.text(0)) }
            chain.usageModel = model
            guard events(chain, tip: tip, segments: segments, database) else { return false }
            chain.tip = tip.id
            chain.stamp = tip.stamp
        }
        chain.turn.logged(tip.lastActivityAt)
        var growth = 0
        for segment in segments {
            let previous = chain.totals[segment.id] ?? (chain.baselined || chain.fresh ? 0 : segment.output)
            if segment.output > previous { growth += segment.output - previous }
            chain.totals[segment.id] = segment.output
        }
        chain.baselined = true
        guard growth > 0 else { return true }
        let info = logInfo(chain)
        let at = min(now.addingTimeInterval(5), [chain.lastMessageAt, tip.lastActivityAt, info.call?.at, chain.creditAt].compactMap { $0 }.max() ?? now)
        chain.creditAt = at
        chain.turn.logged(at)
        chain.turn.addOutput(growth, at: at)
        return true
    }

    private func events(_ chain: Chain, tip: Segment, segments: [Segment], _ database: OpenCodeDatabase) -> Bool {
        let cold = chain.processedID == 0 && !chain.fresh
        var rows: [MessageRow] = []
        let collect: (OpenCodeDatabase.Row) -> Void = { row in
            guard let id = row.integer(0), let role = row.text(1), let at = Self.date(row.double(4)) else { return }
            rows.append(MessageRow(id: id, role: role, finish: row.text(2), toolCallID: row.text(3), at: at,
                                   observed: row.integer(5) == 1, scaffold: row.integer(6) == 1))
        }
        let limit = cold ? 64 : 512
        let filter = "session_id = ? AND id > \(chain.processedID)"
        // Older schemas lack `active`, `observed` and `display_kind`.
        var modern = true
        if !database.query("""
            SELECT id, role, finish_reason, tool_call_id, timestamp, observed, COALESCE(display_kind, '') = 'hidden'
            FROM messages WHERE \(filter) AND active = 1 ORDER BY id DESC LIMIT \(limit)
            """, [tip.id], row: collect) {
            modern = false
            rows.removeAll()
            guard database.query("SELECT id, role, finish_reason, tool_call_id, timestamp, 0, 0 FROM messages WHERE \(filter) ORDER BY id DESC LIMIT \(limit)",
                                 [tip.id], row: collect) else { return false }
        }
        rows.reverse()
        var calls: [Int64: [(id: String, name: String?)]] = [:]
        if let oldest = rows.first?.id {
            // Ids and names only (never arguments); SQLite without JSON functions leaves the calls unnamed and unmatched.
            database.query("""
                SELECT m.id, json_extract(j.value, '$.id'), substr(json_extract(j.value, '$.function.name'), 1, 128)
                FROM messages m, json_each(CASE WHEN json_valid(m.tool_calls) THEN m.tool_calls END) j
                WHERE m.session_id = ? AND m.id >= \(oldest) AND m.role = 'assistant' AND m.tool_calls IS NOT NULL
                """, [tip.id]) { row in
                if let message = row.integer(0), let id = row.text(1) { calls[message, default: []].append((id, row.text(2))) }
            }
        }
        // A cold read that starts inside a turn: its prompt may lie further back, or in an earlier compression segment.
        if cold, let oldest = rows.first, !(oldest.role == "user" && !oldest.observed && !oldest.scaffold) {
            let ids = Array(Set(segments.map(\.id) + [tip.id]))
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let prompt = modern ? " AND observed = 0 AND COALESCE(display_kind, '') != 'hidden'" : ""
            var promptAt: Date?
            database.query("""
                SELECT timestamp FROM messages WHERE session_id IN (\(marks)) AND id < \(oldest.id) AND role = 'user'\(prompt)
                ORDER BY id DESC LIMIT 1
                """, ids) { promptAt = Self.date($0.double(0)) }
            if let promptAt {
                chain.turn.begin(at: promptAt, whole: false)
                chain.promptAt = promptAt
            }
        }
        for row in rows {
            chain.processedID = max(chain.processedID, row.id)
            chain.lastMessageAt = max(chain.lastMessageAt ?? row.at, row.at)
            chain.turn.logged(row.at)
            if row.scaffold { continue }
            // A message from a turn the log already closed must not reopen it.
            let late = !chain.turn.turnOpen && chain.closedAt.map { row.at <= $0 } == true
            switch row.role {
            case "user":
                guard !row.observed else { continue }
                chain.turn.begin(at: row.at, whole: chain.baselined || chain.fresh)
                chain.promptAt = row.at
                chain.closedAt = nil
            case "tool":
                guard !late else { continue }
                chain.turn.resume(at: row.at)
                if let id = row.toolCallID { chain.turn.finishTool(id, at: row.at) }
            case "assistant":
                guard !late else { continue }
                chain.turn.resume(at: row.at)
                // Last to first: the shared bookkeeping shows the newest outstanding call, and Hermes runs a batch in order.
                if let batch = calls[row.id], !batch.isEmpty {
                    for call in batch.reversed() { chain.turn.startTool(call.id, name: call.name, at: row.at) }
                } else if row.finish == "stop" {
                    chain.turn.close(.complete, at: row.at, model: chain.model)
                    chain.closedAt = row.at
                } else if let finish = row.finish, finish != "tool_calls" {
                    chain.turn.close(.interrupted, at: row.at, model: chain.model)
                    chain.closedAt = row.at
                } else {
                    chain.turn.setState(.working, at: row.at)
                }
            default:
                break
            }
        }
        return true
    }

    /// Log liveness, a turn end the database did not record, the context in use and the latest measured request.
    private func applyLog(_ chain: Chain, now: Date) {
        let info = logInfo(chain)
        let ceiling = now.addingTimeInterval(5)
        if let at = info.lastLineAt { chain.turn.logged(min(at, ceiling)) }
        let leased = leases[chain.root].map { $0 > now } == true
        if leased { chain.turn.logged(now) }
        // The end belongs to the open turn when it follows that turn's start line (Hermes stores the prompt within
        // moments of logging it) and every message stored so far; a prompt that interrupted the previous turn comes
        // before that turn's end line but after its start.
        if chain.turn.turnOpen, !leased, let end = info.end, end.at >= (info.start ?? .distantPast),
           end.at >= (chain.lastMessageAt ?? .distantPast),
           chain.promptAt.map({ $0 <= (info.start ?? end.at).addingTimeInterval(2) }) ?? true {
            chain.turn.close(end.state, at: min(end.at, ceiling), model: chain.model)
            chain.closedAt = end.at
        }
        if let call = info.call {
            chain.context = call.input > 0 ? TokenContextUsage(usedTokens: call.input, windowTokens: nil, recordedAt: min(call.at, ceiling), compactedAt: nil) : nil
            if call.provider != "moa", call.output > 0, call.latency > 0 {
                var reading = TelemetryReading(provider: .hermes, at: min(call.at, ceiling))
                reading.sessionID = chain.root
                reading.model = call.model ?? chain.model
                reading.outputTokens = call.output
                reading.requestDurationMs = (call.latency * 1_000).rounded()
                reading.requestDurationIncludesRetries = call.retried
                chain.speed = TokenSpeedMeasurement(reading)
            } else {
                chain.speed = nil
            }
        }
    }

    /// What agent.log says about any segment of the chain.
    private func logInfo(_ chain: Chain) -> LogSession {
        var merged = LogSession()
        for id in Set(chain.segments + [chain.root]) {
            guard let entry = logSessions[id] else { continue }
            merged.lastLineAt = [merged.lastLineAt, entry.lastLineAt].compactMap { $0 }.max()
            merged.start = [merged.start, entry.start].compactMap { $0 }.max()
            if let end = entry.end, end.at > merged.end?.at ?? .distantPast { merged.end = end }
            if let call = entry.call, call.at > merged.call?.at ?? .distantPast { merged.call = call }
        }
        return merged
    }

    // MARK: agent.log

    /// `YYYY-MM-DD HH:MM:SS,mmm LEVEL [<session id>] <logger>: <message>`. Only the first 512 bytes are decoded; only
    /// times, counts, model and provider names are kept.
    private func consume(_ line: Data) {
        guard line.count > 30, line[line.startIndex + 23] == 32 else { return }
        // Python's text-mode log handler ends lines in CRLF on Windows.
        let head = String(decoding: line.prefix(512), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard let date = Self.logDate(head.utf8.prefix(23)) else { return }
        let afterTime = head.dropFirst(24)
        let level = afterTime.prefix { $0 >= "A" && $0 <= "Z" }
        let tagged = afterTime.dropFirst(level.count)
        guard !level.isEmpty, tagged.hasPrefix(" ["), let close = tagged.firstIndex(of: "]") else { return }
        let session = String(tagged[tagged.index(tagged.startIndex, offsetBy: 2)..<close])
        guard (1...64).contains(session.count), session.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0) }) else { return }
        let rest = tagged[tagged.index(after: close)...].dropFirst()
        var entry = logSessions[session] ?? LogSession()
        entry.lastLineAt = max(entry.lastLineAt ?? date, date)
        let warning = level == "WARNING" || level == "ERROR"
        if rest.hasPrefix("agent.conversation_loop: ") {
            let message = rest.dropFirst(25)
            if message.hasPrefix("API call #") {
                var call = Call(at: date, retried: entry.retrying)
                for field in message.split(separator: " ") {
                    guard let equals = field.firstIndex(of: "=") else { continue }
                    let value = field[field.index(after: equals)...]
                    switch field[..<equals] {
                    case "model": call.model = Self.name(String(value))
                    case "provider": call.provider = String(value.prefix(64))
                    case "in": call.input = Int(value).map { max(0, $0) } ?? 0
                    case "out": call.output = Int(value).map { max(0, $0) } ?? 0
                    case "latency": call.latency = Double(value.hasSuffix("s") ? value.dropLast() : value).flatMap { $0.isFinite ? $0 : nil } ?? 0
                    default: break
                    }
                }
                entry.call = call
                entry.retrying = false
            } else if message.hasPrefix("Turn ended: reason=") {
                let reason = message.dropFirst(19)
                entry.end = (date, reason.hasPrefix("text_response") ? .complete : .interrupted)
            } else if message.hasPrefix("API call failed after") {
                entry.end = (date, .interrupted)
                entry.retrying = false
            } else if warning, message.hasPrefix("Retrying API call") || message.hasPrefix("API call failed")
                        || message.hasPrefix("Invalid API response") {
                entry.retrying = true
            }
        } else if warning, rest.hasPrefix("agent.chat_completion_helpers: ") {
            entry.retrying = true
        } else if rest.hasPrefix("agent.turn_context: conversation turn:") {
            entry.start = date
            entry.retrying = false
        }
        logSessions[session] = entry
        if logSessions.count > 512, let oldest = logSessions.min(by: { ($0.value.lastLineAt ?? .distantPast) < ($1.value.lastLineAt ?? .distantPast) }) {
            logSessions[oldest.key] = nil
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    /// Python logging's local `asctime`: `2026-08-18 21:31:39,780`.
    static func logDate<Bytes: Collection>(_ bytes: Bytes) -> Date? where Bytes.Element == UInt8 {
        let text = Array(bytes)
        guard text.count == 23, text[4] == 45, text[7] == 45, text[10] == 32, text[13] == 58, text[16] == 58, text[19] == 44 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard (48...57).contains(text[index]) else { return nil }
                value = value * 10 + Int(text[index] - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10), let hour = number(11..<13),
              let minute = number(14..<16), let second = number(17..<19), let millisecond = number(20..<23),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
        else { return nil }
        return date.addingTimeInterval(Double(millisecond) / 1_000)
    }

    // MARK: Readings

    func isRecent(at now: Date) -> Bool { chains.values.contains { $0.turn.isRecent(at: now) } }

    func readings(id: String, now: Date) -> [TokenReading] {
        chains.values.compactMap { chain -> TokenReading? in
            let cwd = chain.cwd ?? chain.parent.flatMap { chains[$0]?.cwd }
            guard var reading = chain.turn.reading(source: .hermes, id: "\(id)#\(chain.root)", model: chain.model, cwd: cwd, now: now) else { return nil }
            reading.sessionID = chain.root
            reading.title = chain.title
            if chain.spawned {
                reading.isSubagent = true
                reading.parentSessionID = chain.parent
                reading.agentID = chain.root
            }
            if let tool = reading.toolName { reading.toolCategory = Self.category(tool) }
            reading.context = chain.context
            reading.speedMeasurement = chain.speed
            return reading
        }
    }

    /// Hermes's built-in tool names; MCP tools are `mcp__<server>__<tool>`.
    static func category(_ name: String) -> ToolCategory {
        if name.hasPrefix("mcp__") { return .mcp }
        if name.hasPrefix("browser_") { return .web }
        switch name {
        case "terminal", "process", "execute_code", "read_terminal", "close_terminal": return .command
        case "read_file", "write_file", "patch", "search_files", "read_preview": return .file
        case "web_search", "web_extract", "x_search": return .web
        case "delegate_task": return .agent
        case "clarify": return .question
        default: return .other
        }
    }

    // MARK: Values

    /// Opens the store read-only. A WAL database whose last writer closed has no `-wal`/`-shm`, and a read-only
    /// connection cannot create them, so SQLite refuses it; with no WAL file nothing is mid-write and nothing reaches the
    /// main file until a writer's checkpoint, so it is read as immutable then.
    private static func open(_ path: String) -> OpenCodeDatabase? {
        if let database = OpenCodeDatabase(path: path), database.query("SELECT 1 FROM sqlite_master LIMIT 1", row: { _ in }) { return database }
        guard !FileManager.default.fileExists(atPath: path + "-wal"), isWALDatabase(path) else { return nil }
        return OpenCodeDatabase(path: path, immutable: true)
    }

    /// The header's file format bytes say WAL (2).
    private static func isWALDatabase(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        return header[header.startIndex + 18] == 2 && header[header.startIndex + 19] == 2
    }

    fileprivate static func date(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    fileprivate static func count(_ value: Int64?) -> Int {
        guard let value, value > 0 else { return 0 }
        return Int(min(value, Int64(Int32.max)))
    }

    fileprivate static func name(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.count <= 256 else { return nil }
        return text
    }
}

// MARK: - Model

/// One `sessions` row: metadata and counters only.
private struct Segment {
    let id: String
    var source: String?
    var parent: String?
    var model: String?
    var cwd: String?
    var title: String?
    var startedAt: Date?
    var endedAt: Date?
    var endReason: String?
    var lastActivityAt: Date?
    var output = 0
    var messageCount = 0
    var delegated = false
    var branched = false

    init(id: String) { self.id = id }

    /// A delegated subagent (or a tool-spawned child); its own row under its parent.
    var spawned: Bool { source == "subagent" || delegated || (source == "tool" && parent != nil) }
    /// Continues its parent when that parent ended in compression (Hermes's own lineage rule, plus older subagents).
    var continuesParent: Bool { !delegated && !branched && source != "tool" && source != "subagent" }
    var activity: Date { [startedAt, lastActivityAt, endedAt].compactMap { $0 }.max() ?? .distantPast }
    /// Changes whenever a message is stored or the session's counters, end or activity move.
    var stamp: [Double] {
        [Double(messageCount), Double(output), endedAt?.timeIntervalSince1970 ?? 0, lastActivityAt?.timeIntervalSince1970 ?? 0]
    }
}

private struct MessageRow {
    let id: Int64
    let role: String
    let finish: String?
    let toolCallID: String?
    let at: Date
    let observed: Bool
    /// Compaction references and interruption placeholders (`display_kind = 'hidden'`): model-facing scaffolding. Other
    /// kinds (an internal notification, a synthesized continuation) still open a turn.
    let scaffold: Bool
}

/// One compression chain (most are a single session), named after its first session.
private final class Chain {
    let root: String
    /// Started after this reader's first read: its totals start at zero, so its first turn is whole.
    let fresh: Bool
    let turn = LogTurnState(inputTools: ["clarify"])
    var segments: [String] = []
    var tip = ""
    var stamp: [Double] = []
    /// Output total per segment at the latest read.
    var totals: [String: Int] = [:]
    var baselined = false
    var processedID: Int64 = 0
    var promptAt: Date?
    var lastMessageAt: Date?
    var closedAt: Date?
    var creditAt: Date?
    var usageModel: String?
    var sessionModel: String?
    var cwd: String?
    var title: String?
    var spawned = false
    var parent: String?
    var context: TokenContextUsage?
    var speed: TokenSpeedMeasurement?

    init(root: String, fresh: Bool) {
        self.root = root
        self.fresh = fresh
    }

    var model: String? { usageModel ?? sessionModel }
}

private struct Call {
    let at: Date
    var model: String?
    var provider: String?
    var input = 0
    var output = 0
    var latency: Double = 0
    var retried: Bool

    init(at: Date, retried: Bool) {
        self.at = at
        self.retried = retried
    }
}

/// What agent.log said about one session id.
private struct LogSession {
    var lastLineAt: Date?
    /// The latest `conversation turn` (turn start) line.
    var start: Date?
    var end: (at: Date, state: TokenActivityState)?
    var call: Call?
    /// A retry or failure line since the latest `API call` line.
    var retrying = false
}
