import Foundation
import SQLite3

extension TokenLogFormat {
    /// OpenCode's SQLite store: `opencode.db`, a channel build's `opencode-<channel>.db`, or the `OPENCODE_DB` file.
    /// One reader covers every session in it.
    static let opencode = TokenLogFormat(files: { roots, discovery in
        discovery.recent(roots.flatMap(discovery.children).filter { OpenCodeLog.isDatabase($0.path) })
    }, isLog: OpenCodeLog.isDatabase, open: { OpenCodeLog(url: $0) })
}

/// Reads OpenCode sessions from its database, opened read-only (OpenCode writes it in WAL mode).
/// - Re-queried only when the database or its WAL changed, and then only sessions updated within the hour, with an open
///   turn, or whose `time_updated` moved; message bodies are fetched again only when a row's `time_updated` changes. A
///   read the database refused (busy) is never cached: that session is queried again on the next read.
/// - Only roles, times, finish reasons, token counts, model, agent, cwd, tool names/states and the session's generated or
///   renamed title are kept; never message text.
/// - A message body over 64 KB is never loaded whole when its first 4 KB name a user message (a summary with file diffs
///   can reach hundreds of MB). Anything else, such as an assistant message holding a provider's error page, is loaded up
///   to 16 MB; past that an assistant message counts as a failed request.
/// - Turn state: an assistant message without `time.completed` is generating (a running tool shows as `tool`, the
///   question tool as `input`); `finish: "tool-calls"` continues the loop; another finish ends the turn (`complete`); an
///   error or no finish at all ends it as `interrupted`.
/// - Speed: per completed assistant message, output + reasoning tokens over the time from `time.created` to its last
///   generated part (text or reasoning end, or a tool's execution start), so a tool's run time is not counted. Request
///   processing rate, first-response wait included; nothing is measured when a part could not be read.
final class OpenCodeLog: TokenLogReader {
    let url: URL
    private var signature: [Int64]?
    private var sessions: [String: Session] = [:]

    init(url: URL) { self.url = url }

    /// A database `files` lists: OpenCode's default or channel file name, or the `OPENCODE_DB` file.
    static func isDatabase(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "opencode.db" || (name.hasPrefix("opencode-") && name.hasSuffix(".db")) || path == overridePath
    }

    private static let overridePath = TokenProvider.openCodeDatabasePath(FileManager.default.homeDirectoryForCurrentUser,
                                                                         ProcessInfo.processInfo.environment)?.path

    // MARK: Reading

    func read(tailLimit: Int, now: Date) {
        guard let current = currentSignature(), current != signature, let database = OpenCodeDatabase(path: url.path) else { return }
        guard database.execute("BEGIN") else { return }
        defer { _ = database.execute("COMMIT") }
        var listed: [(id: String, parent: String?, directory: String?, agent: String?, model: String?, updated: Date, title: String?)] = []
        // The title is bounded in SQL; a generated or renamed one is short.
        let columns = "id, parent_id, directory, agent, model, time_updated, substr(title, 1, 1024) FROM session"
        let order = "ORDER BY time_updated DESC LIMIT 64"
        let collect: (OpenCodeDatabase.Row) -> Void = { row in
            guard let id = row.text(0), let updated = row.date(5) else { return }
            listed.append((id, row.text(1), row.text(2), row.text(3), row.text(4), updated, row.text(6)))
        }
        // Older schemas lack time_archived.
        guard database.query("SELECT \(columns) WHERE time_archived IS NULL \(order)", row: collect)
                || database.query("SELECT \(columns) \(order)", row: collect) else { return }
        var kept: [String: Session] = [:]
        var complete = true
        for (offset, row) in listed.enumerated() {
            let existing = sessions[row.id]
            guard offset < 32 || now.timeIntervalSince(row.updated) <= 3_600 || existing?.summary.open == true else { continue }
            let session = existing ?? Session(id: row.id)
            let moved = existing == nil || session.updated != row.updated
            session.parentID = row.parent
            session.directory = row.directory
            session.agent = row.agent
            session.sessionModel = row.model.flatMap(Self.modelID)
            session.title = Self.title(row.title)
            session.updated = row.updated
            if moved || now.timeIntervalSince(row.updated) <= 3_600 || session.summary.open, !refresh(session, database) {
                // Keeps what was read before; `distantPast` makes the next read refresh it again.
                session.updated = .distantPast
                complete = false
            }
            kept[row.id] = session
        }
        sessions = kept
        signature = complete ? current : nil
    }

    /// Database and WAL identity, size and modification time; any write changes one of them.
    private func currentSignature() -> [Int64]? { OpenCodeDatabase.signature(url.path) }

    /// False when the database refused a read; the session then keeps its previous messages.
    private func refresh(_ session: Session, _ database: OpenCodeDatabase) -> Bool {
        var index: [(id: String, created: Date, updated: Date)] = []
        guard database.query("SELECT id, time_created, time_updated FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 200",
                             [session.id], row: { row in
            if let id = row.text(0), let created = row.date(1), let updated = row.date(2) { index.append((id, created, updated)) }
        }) else { return false }
        var messages: [Message] = []
        for entry in index {
            if let cached = session.cache[entry.id], cached.updated == entry.updated {
                messages.append(cached)
                continue
            }
            guard let message = message(entry, database) else { return false }
            messages.append(message)
        }
        session.messages = messages
        session.cache = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let newest = messages.first
        session.openParts = newest.flatMap { $0.role == .assistant && $0.completed == nil ? parts(of: $0.id, database) : nil }
        if let measured = messages.first(where: { $0.role == .assistant && $0.completed != nil && !$0.failed && $0.generated > 0 }) {
            if session.speed?.messageID != measured.id || session.speed?.updated != measured.updated {
                session.speed = (measured.id, measured.updated, parts(of: measured.id, database).flatMap { measurement(measured, $0) })
            }
        } else {
            session.speed = nil
        }
        session.summary = Summary(session)
        return true
    }

    /// One message's metadata; nil when the database refused the read or the row changed under it.
    private func message(_ entry: (id: String, created: Date, updated: Date), _ database: OpenCodeDatabase) -> Message? {
        var body: String?
        var rowid: Int64?
        guard database.query("SELECT CASE WHEN \(database.sizeOfData) <= 65536 THEN data END, rowid FROM message WHERE id = ?",
                             [entry.id], row: { body = $0.text(0); rowid = $0.integer(1) }), let rowid else { return nil }
        if let body { return Message(id: entry.id, created: entry.created, updated: entry.updated, body: body) }
        guard let head = database.head(ofMessage: rowid) else { return nil }
        let role = Message.role(inHead: head)
        if role == .user { return Message(id: entry.id, created: entry.created, updated: entry.updated, role: .user) }
        var full: String?
        guard database.query("SELECT CASE WHEN \(database.sizeOfData) <= 16777216 THEN data END FROM message WHERE id = ?",
                             [entry.id], row: { full = $0.text(0) }) else { return nil }
        if let full { return Message(id: entry.id, created: entry.created, updated: entry.updated, body: full) }
        var message = Message(id: entry.id, created: entry.created, updated: entry.updated, role: role)
        if role == .assistant {
            message.failed = true
            message.completed = entry.updated
        }
        return message
    }

    private func parts(of message: String, _ database: OpenCodeDatabase) -> [Part]? {
        var parts: [Part] = []
        guard database.query("SELECT time_updated, CASE WHEN \(database.sizeOfData) <= 262144 THEN data END FROM part WHERE message_id = ? ORDER BY id",
                             [message], row: { row in
            if let updated = row.date(0) { parts.append(Part(updated: updated, body: row.text(1))) }
        }) else { return nil }
        return parts
    }

    /// Output + reasoning over created → last generated part; nil when a part was unreadable or no time was recorded.
    private func measurement(_ message: Message, _ parts: [Part]) -> TokenSpeedMeasurement? {
        guard let completed = message.completed, !parts.contains(where: { !$0.readable }) else { return nil }
        let ends = parts.compactMap { part -> Date? in
            switch part.type {
            case "text", "reasoning": return part.end ?? part.updated
            case "tool": return part.toolStart
            default: return nil
            }
        }
        guard let end = ends.max() else { return nil }
        let milliseconds = end.timeIntervalSince(message.created) * 1_000
        guard milliseconds.isFinite, milliseconds > 0 else { return nil }
        var reading = TelemetryReading(provider: .opencode, at: completed)
        reading.model = message.model
        reading.outputTokens = message.generated
        reading.requestDurationMs = milliseconds.rounded()
        reading.requestDurationIncludesRetries = parts.contains { $0.type == "retry" }
        return TokenSpeedMeasurement(reading)
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
            var reading = TokenReading(source: .opencode, id: "\(id)#\(session.id)")
            reading.sessionID = session.id
            reading.title = session.title
            if let parent = session.parentID {
                reading.isSubagent = true
                reading.parentSessionID = parent
                reading.agentID = session.id
                reading.agentRole = TokenLogParser.label(summary.agent ?? session.agent)
            }
            if let cwd = summary.cwd ?? session.directory, !cwd.isEmpty {
                reading.project = URL(fileURLWithPath: cwd).lastPathComponent
                reading.projectPath = cwd
            }
            reading.model = summary.model ?? session.sessionModel
            reading.context = summary.context
            reading.lastActivity = min(lastActivity, ceiling)
            let liveAt = min([summary.lastLogAt, lastActivity].compactMap { $0 }.max() ?? lastActivity, ceiling)
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
            reading.currentTurnOutputTokens = summary.open ? summary.turnOutput : nil
            reading.lastOutputAt = summary.outputs.last?.at
            reading.lastOutputDelta = summary.outputs.last?.tokens
            reading.recentOutputs = summary.outputs.filter {
                let age = now.timeIntervalSince($0.at)
                return age >= -5 && age <= TokenTracker.recentOutputWindow
            }
            reading.lastOutputTokens = summary.completion?.output
            reading.speedMeasurement = session.speed?.measurement
            reading.sampledAt = now
            return reading
        }
    }

    /// OpenCode's built-in tool names (lowercase); MCP tools are `<server>_<tool>` and stay `other`.
    static func category(_ name: String) -> ToolCategory {
        switch name {
        case "bash": return .command
        case "read", "write", "edit", "multiedit", "patch", "apply_patch", "grep", "glob", "list", "ls", "lsp": return .file
        case "webfetch", "websearch", "codesearch": return .web
        case "task": return .agent
        case "question": return .question
        default: return .other
        }
    }

    fileprivate static func modelID(_ json: String) -> String? {
        guard json.utf8.count <= 4_096, let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        return text(object["id"]) ?? text(object["modelID"])
    }

    /// `session.title` once generated or renamed; OpenCode's placeholder ("New session - <ISO time>", "Child session - …",
    /// its `isDefaultTitle`) is no title.
    static func title(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let placeholder = #"^(New session - |Child session - )\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        guard raw.range(of: placeholder, options: .regularExpression) == nil else { return nil }
        return SessionTitle.clean(raw)
    }

    fileprivate static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= 256 else { return nil }
        return text
    }

    fileprivate static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1_000)
    }

    fileprivate static func count(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { return 0 }
        return Int(min(number.doubleValue, Double(Int32.max)))
    }
}

// MARK: - Model

private enum Role { case user, assistant, other }

/// One message's metadata; never its text.
private struct Message {
    let id: String
    let created: Date
    let updated: Date
    var role: Role = .other
    var completed: Date?
    var finish: String?
    var failed = false
    var model: String?
    var parentID: String?
    var cwd: String?
    var agent: String?
    /// Output + reasoning tokens (OpenCode records them apart).
    var generated = 0
    /// Input + cache read + cache write of this request.
    var context = 0

    /// A message known only by its role (a body too large to load).
    init(id: String, created: Date, updated: Date, role: Role) {
        self.id = id
        self.created = created
        self.updated = updated
        self.role = role
    }

    init(id: String, created: Date, updated: Date, body: String) {
        self.id = id
        self.created = created
        self.updated = updated
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return }
        switch object["role"] as? String {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return
        }
        let time = object["time"] as? [String: Any]
        completed = OpenCodeLog.milliseconds(time?["completed"])
        finish = OpenCodeLog.text(object["finish"])
        failed = object["error"] != nil && !(object["error"] is NSNull)
        model = OpenCodeLog.text(object["modelID"]) ?? (object["model"] as? [String: Any]).flatMap { OpenCodeLog.text($0["modelID"]) }
        parentID = OpenCodeLog.text(object["parentID"])
        cwd = (object["path"] as? [String: Any]).flatMap { $0["cwd"] as? String }
        agent = OpenCodeLog.text(object["agent"]) ?? OpenCodeLog.text(object["mode"])
        if let tokens = object["tokens"] as? [String: Any] {
            generated = OpenCodeLog.count(tokens["output"]) + OpenCodeLog.count(tokens["reasoning"])
            let cache = tokens["cache"] as? [String: Any]
            context = OpenCodeLog.count(tokens["input"]) + OpenCodeLog.count(cache?["read"]) + OpenCodeLog.count(cache?["write"])
        }
    }

    /// The role from the first bytes of a message body. OpenCode writes `role` among the first keys, and any `"role"` in
    /// text would be escaped (`\"role\"`), so the first unescaped one is the message's own.
    static func role(inHead head: Data) -> Role {
        let text = String(decoding: head, as: UTF8.self)
        guard let key = text.range(of: "\"role\"") else { return .other }
        let rest = text[key.upperBound...].drop { $0 == " " || $0 == ":" }
        if rest.hasPrefix("\"user\"") { return .user }
        if rest.hasPrefix("\"assistant\"") { return .assistant }
        return .other
    }
}

/// One part's type, tool name and state, and its times; never its text, input or output.
private struct Part {
    let updated: Date
    var readable = false
    var type: String?
    var tool: String?
    var status: String?
    var toolStart: Date?
    var end: Date?

    init(updated: Date, body: String?) {
        self.updated = updated
        guard let body, let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return }
        readable = true
        type = OpenCodeLog.text(object["type"])
        tool = OpenCodeLog.text(object["tool"])
        let state = object["state"] as? [String: Any]
        status = OpenCodeLog.text(state?["status"])
        toolStart = OpenCodeLog.milliseconds((state?["time"] as? [String: Any])?["start"])
        end = OpenCodeLog.milliseconds((object["time"] as? [String: Any])?["end"])
    }
}

private final class Session {
    let id: String
    var parentID: String?
    var directory: String?
    var agent: String?
    var sessionModel: String?
    var title: String?
    var updated = Date.distantPast
    /// Newest first, at most 200.
    var messages: [Message] = []
    var cache: [String: Message] = [:]
    /// Parts of the newest message while it is an assistant message still generating.
    var openParts: [Part]?
    var speed: (messageID: String, updated: Date, measurement: TokenSpeedMeasurement?)?
    var summary = Summary()

    init(id: String) { self.id = id }
}

/// What a session's messages say, apart from the clock.
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
    var cwd: String?
    var agent: String?
    var context: TokenContextUsage?

    init() {}

    init(_ session: Session) {
        let messages = session.messages
        guard let newest = messages.first else { return }
        let assistants = messages.filter { $0.role == .assistant }
        lastActivity = messages.map { $0.completed ?? $0.created }.max()
        lastLogAt = ([messages.map(\.updated).max()] + (session.openParts ?? []).map(\.updated)).compactMap { $0 }.max()
        model = assistants.lazy.compactMap(\.model).first
        cwd = assistants.lazy.compactMap(\.cwd).first
        agent = assistants.lazy.compactMap(\.agent).first
        if let latest = assistants.first(where: { $0.completed != nil && $0.context > 0 }), let at = latest.completed {
            context = TokenContextUsage(usedTokens: latest.context, windowTokens: nil, recordedAt: at, compactedAt: nil)
        }
        outputs = assistants.compactMap { message in
            message.completed.flatMap { message.generated > 0 ? TokenOutputEvent(at: $0, tokens: message.generated) : nil }
        }.sorted { $0.at < $1.at }

        // The person's message that opened a turn, and its output when the whole turn is in the window.
        func turn(of user: String?) -> (start: Date, output: Int)? {
            guard let user, let opener = messages.first(where: { $0.id == user && $0.role == .user }) else { return nil }
            return (opener.created, assistants.filter { $0.parentID == user }.reduce(0) { $0 + $1.generated })
        }
        switch newest.role {
        case .user:
            open = true
            state = .working
            startedAt = newest.created
            turnOutput = 0
        case .assistant:
            if newest.completed == nil {
                open = true
                state = .working
                let parts = session.openParts ?? []
                let running = parts.filter { $0.type == "tool" && ($0.status == "pending" || $0.status == "running") }
                if let tool = running.last(where: { $0.tool == "question" }) ?? running.last {
                    toolName = tool.tool
                    waitsForInput = tool.tool == "question"
                    state = waitsForInput ? .input : .tool
                } else if parts.last(where: { $0.type == "text" || $0.type == "reasoning" || $0.type == "tool" })?.type == "text" {
                    state = .output
                }
            } else if newest.failed || newest.finish == nil {
                state = .interrupted
            } else if newest.finish == "tool-calls" {
                open = true
                state = .working
            } else {
                state = .complete
            }
            if open, let turn = turn(of: newest.parentID) {
                startedAt = turn.start
                turnOutput = turn.output
            }
        case .other:
            state = .idle
        }
        // The newest turn that ended normally, fully seen.
        if let last = assistants.first(where: { $0.completed != nil && !$0.failed && $0.finish != nil && $0.finish != "tool-calls" }),
           let at = last.completed, let turn = turn(of: last.parentID), turn.output > 0 {
            completion = (turn.output, at)
        }
    }
}

// MARK: - SQLite

/// A read-only connection to an SQLite database (OpenCode's; omp's and Pi's usage history); system libsqlite3.
final class OpenCodeDatabase {
    private let handle: OpaquePointer
    /// Bytes of `data` without loading it (`octet_length`, SQLite 3.43+); older libraries load the value to measure it.
    private(set) var sizeOfData = "octet_length(data)"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }
        func date(_ column: Int32) -> Date? {
            guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { return nil }
            let value = sqlite3_column_int64(statement, column)
            return value > 0 ? Date(timeIntervalSince1970: Double(value) / 1_000) : nil
        }
        func integer(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_INTEGER ? sqlite3_column_int64(statement, column) : nil
        }
        /// REAL or INTEGER as a number; nil for NULL or text.
        func double(_ column: Int32) -> Double? {
            let type = sqlite3_column_type(statement, column)
            return type == SQLITE_FLOAT || type == SQLITE_INTEGER ? sqlite3_column_double(statement, column) : nil
        }
    }

    /// Database and WAL identity, size and modification time; any write changes one of them. Nil when the file is missing.
    static func signature(_ path: String) -> [Int64]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        var result = [Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_size),
                      Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
        var wal = stat()
        if stat(path + "-wal", &wal) == 0 {
            result += [Int64(wal.st_size), Int64(wal.st_mtimespec.tv_sec), Int64(wal.st_mtimespec.tv_nsec)]
        }
        return result
    }

    /// The first `count` bytes of a message's `data`, read in place (incremental blob I/O), so a body of hundreds of MB is
    /// never loaded; nil when the row cannot be opened.
    func head(ofMessage rowid: Int64, count: Int32 = 4_096) -> Data? {
        var blob: OpaquePointer?
        defer { sqlite3_blob_close(blob) }
        guard sqlite3_blob_open(handle, "main", "message", "data", rowid, 0, &blob) == SQLITE_OK, let opened = blob else { return nil }
        let length = min(count, sqlite3_blob_bytes(opened))
        var data = Data(count: Int(length))
        let status = data.withUnsafeMutableBytes { sqlite3_blob_read(opened, $0.baseAddress, length, 0) }
        return status == SQLITE_OK ? data : nil
    }

    init?(path: String) {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            return nil
        }
        handle = connection
        sqlite3_busy_timeout(handle, 250)
        if !query("SELECT octet_length('')", row: { _ in }) { sizeOfData = "length(CAST(data AS BLOB))" }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) -> Bool { sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK }

    /// Runs one statement; false when it could not be prepared or stepped to the end.
    @discardableResult
    func query(_ sql: String, _ bindings: [String] = [], row: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(Row(statement: statement))
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }
}
