import Foundation
import SQLite3

extension TokenLogFormat {
    /// The SQLite store of OpenCode and of the apps built on it (`OpenCodeApp`): `<app>.db`, a channel build's
    /// `<app>-<channel>.db`, or the `<APP>_DB` file. One reader covers every session in it.
    static let opencode = TokenLogFormat(files: { roots, discovery in
        discovery.recent(roots.flatMap(discovery.children).filter { OpenCodeLog.isDatabase($0.path) })
    }, isLog: OpenCodeLog.isDatabase, open: { OpenCodeLog(url: $0) })
}

/// OpenCode and the apps built on its store, which keep its schema in their own data folder: Kilo Code (the Kilo CLI and
/// the extension rebuilt on it) and MiMo Code.
struct OpenCodeApp {
    /// The data folder's name and the database file stem: `<name>.db`, a channel build's `<name>-<channel>.db`.
    let name: String
    /// The variable naming the database file, resolved like the app does: absolute, else inside the data folder.
    let variable: String
    /// `TokenReading.clientName` of its rows; nil for OpenCode itself.
    let client: String?

    static let all = [OpenCodeApp(name: "opencode", variable: "OPENCODE_DB", client: nil),
                      OpenCodeApp(name: "kilo", variable: "KILO_DB", client: "Kilo Code"),
                      OpenCodeApp(name: "mimocode", variable: "MIMOCODE_DB", client: "MiMo Code")]

    /// `$XDG_DATA_HOME/<name>`, else ~/.local/share/<name> (xdg-basedir, macOS too); MiMo Code's `$MIMOCODE_HOME/data`.
    func dataFolder(_ home: URL, _ environment: [String: String]) -> URL {
        if name == "mimocode", let root = environment.path("MIMOCODE_HOME") { return root.appendingPathComponent("data") }
        return TokenProvider.dataHome(home, environment).appendingPathComponent(name)
    }

    /// The `variable` file: an absolute path, else a path inside the data folder; `:memory:` is no file.
    func databasePath(_ home: URL, _ environment: [String: String]) -> URL? {
        guard let value = environment[variable], !value.isEmpty, value != ":memory:" else { return nil }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL
            : dataFolder(home, environment).appendingPathComponent(value).standardizedFileURL
    }

    private static let overrides: [(path: String, app: OpenCodeApp)] = all.compactMap { app in
        app.databasePath(FileManager.default.homeDirectoryForCurrentUser, ProcessInfo.processInfo.environment).map { ($0.path, app) }
    }

    /// The app whose database a path is: a `variable` file, else by file name. Kilo's channel build keeps a
    /// pre-existing `opencode-<channel>.db` in its own folder.
    static func of(_ path: String) -> OpenCodeApp? {
        if let override = overrides.first(where: { $0.path == path }) { return override.app }
        let url = URL(fileURLWithPath: path)
        let file = url.lastPathComponent
        guard let app = all.first(where: { file == "\($0.name).db" || (file.hasPrefix("\($0.name)-") && file.hasSuffix(".db")) }) else { return nil }
        return app.name == "opencode" && url.deletingLastPathComponent().lastPathComponent == "kilo" ? all[1] : app
    }
}

/// Reads OpenCode sessions from its database, opened read-only (OpenCode writes it in WAL mode).
/// - Two stores: v1 `message` + `part` rows, and v2 `session_message` rows (role in `type`, a step's tools, text and
///   reasoning inside its `content`), with sessions in `session` or, since v2's split, `session_v2`. A database migrated to
///   v2 keeps its v1 tables and copies their sessions under the same ids, so each session is read from the one store whose
///   newest message is newer (v2 on a tie) and never counted twice; a session in both session tables takes the row
///   updated last.
/// - Re-queried only when the database or its WAL changed, and then only sessions updated within the hour, with an open
///   turn, or whose `time_updated` moved; message rows are fetched again only when their `time_updated` changes. v2 steps
///   leave the session's `time_updated` alone, so sessions with v2 messages changed within the hour count as updated
///   then. A read the database refused (busy) is never cached: that session is queried again on the next read.
/// - Only roles, times, finish reasons, token counts, model, agent, cwd, tool names/states and the session's generated or
///   renamed title are kept; never message text. v2 rows are read with SQLite's JSON functions, so their text never
///   leaves SQLite.
/// - A v1 message body over 64 KB is never loaded whole when its first 4 KB name a user message (a summary with file
///   diffs can reach hundreds of MB). Anything else, such as an assistant message holding a provider's error page, is
///   loaded up to 16 MB; past that (v2: a row over 16 MB) an assistant message counts as a failed request.
/// - Turn state: an assistant message without `time.completed` is generating (a running tool shows as `tool`, the
///   question tool as `input`); `finish: "tool-calls"` continues the loop; another finish ends the turn (`complete`); an
///   error or no finish at all ends it as `interrupted`. v2 has no parent link: a turn runs from the prompt that opened
///   it (with idle markers, the first prompt after the last one; else the latest), and an idle marker ends it with its
///   outcome.
/// - Speed: per completed assistant message, output + reasoning tokens over the time from `time.created` to its last
///   generated part (text or reasoning end, or a tool's execution start), so a tool's run time is not counted. v2 records
///   no text times: its `time.streamed` when recorded, else the step's end when it ran no tool, else the last tool's
///   execution start when a tool came last. Request processing rate, first-response wait included; nothing is measured
///   when a part could not be read.
final class OpenCodeLog: TokenLogReader {
    let url: URL
    /// "Kilo Code" or "MiMo Code" for those apps' databases; nil for OpenCode's.
    let clientName: String?
    private var signature: [Int64]?
    private var sessions: [String: Session] = [:]

    init(url: URL) {
        self.url = url
        clientName = OpenCodeApp.of(url.path)?.client
    }

    /// A database `files` lists: an `OpenCodeApp`'s default or channel file name, or its `<APP>_DB` file.
    static func isDatabase(_ path: String) -> Bool { OpenCodeApp.of(path) != nil }

    // MARK: Reading

    func read(tailLimit: Int, now: Date) {
        guard let current = currentSignature(), current != signature, let database = OpenCodeDatabase(path: url.path) else { return }
        guard database.execute("BEGIN") else { return }
        defer { _ = database.execute("COMMIT") }
        guard let schema = Schema(database) else { return }
        var listed: [String: Listed] = [:]
        let collect: (OpenCodeDatabase.Row) -> Void = { row in
            guard let id = row.text(0), let updated = row.date(5) else { return }
            // The first table listed (`session_v2`) wins a tie.
            if let known = listed[id], known.updated >= updated { return }
            listed[id] = Listed(id: id, parent: row.text(1), directory: row.text(2), agent: row.text(3), model: row.text(4),
                                updated: updated, title: row.text(7) == "fallback" ? nil : row.text(6))
        }
        for table in schema.sessionTables {
            guard database.query("SELECT \(schema.sessionColumns(table)) WHERE \(schema.unarchived(table)) ORDER BY time_updated DESC LIMIT 64",
                                 row: collect) else { return }
        }
        var moved: [String: Date] = [:]
        if schema.hasV2 {
            let since = Int64((now.timeIntervalSince1970 - 3_600) * 1_000)
            guard database.query("SELECT session_id, MAX(time_updated) FROM session_message WHERE time_created >= \(since) GROUP BY session_id",
                                 row: { row in if let id = row.text(0), let updated = row.date(1) { moved[id] = updated } }) else { return }
        }
        let missing = Set(moved.keys).union(sessions.values.filter(\.summary.open).map(\.id)).subtracting(listed.keys)
        for id in missing.sorted() {
            for table in schema.sessionTables {
                guard database.query("SELECT \(schema.sessionColumns(table)) WHERE id = ? AND \(schema.unarchived(table))", [id], row: collect)
                else { return }
            }
        }
        let ordered = listed.values.map { row -> Listed in
            var row = row
            if let changed = moved[row.id], changed > row.updated { row.updated = changed }
            return row
        }.sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.id < $1.id }
        var kept: [String: Session] = [:]
        var complete = true
        for (offset, row) in ordered.enumerated() {
            let existing = sessions[row.id]
            guard offset < 32 || now.timeIntervalSince(row.updated) <= 3_600 || existing?.summary.open == true else { continue }
            let session = existing ?? Session(id: row.id)
            let changed = existing == nil || session.updated != row.updated
            session.parentID = row.parent
            session.directory = row.directory
            session.agent = row.agent
            session.sessionModel = row.model.flatMap(Self.modelID)
            session.title = Self.title(row.title)
            session.updated = row.updated
            if changed || now.timeIntervalSince(row.updated) <= 3_600 || session.summary.open, !refresh(session, database, schema) {
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
    private func refresh(_ session: Session, _ database: OpenCodeDatabase, _ schema: Schema) -> Bool {
        var v1: [Entry] = []
        var v2: [Entry] = []
        if schema.hasV1 {
            guard database.query("SELECT id, time_created, time_updated FROM message WHERE session_id = ?\(schema.mainThread) ORDER BY time_created DESC, id DESC LIMIT 200",
                                 [session.id], row: { row in
                if let id = row.text(0), let created = row.date(1), let updated = row.date(2) { v1.append(Entry(id: id, created: created, updated: updated, type: nil)) }
            }) else { return false }
        }
        if schema.hasV2 {
            guard database.query("SELECT id, time_created, time_updated, type FROM session_message WHERE session_id = ? AND type IN ('user', 'assistant', 'idle') ORDER BY seq DESC LIMIT 200",
                                 [session.id], row: { row in
                if let id = row.text(0), let created = row.date(1), let updated = row.date(2) { v2.append(Entry(id: id, created: created, updated: updated, type: row.text(3))) }
            }) else { return false }
        }
        let v2Newest = v2.map(\.created).max()
        let useV2 = v2Newest.map { newest in v1.map(\.created).max().map { newest >= $0 } ?? true } ?? false
        if session.v2 != useV2 {
            session.v2 = useV2
            session.cache = [:]
            session.speed = nil
        }
        var messages: [Message] = []
        for entry in useV2 ? v2 : v1 {
            if let cached = session.cache[entry.id], cached.updated == entry.updated {
                messages.append(cached)
                continue
            }
            guard let message = useV2 ? v2Message(entry, database) : message(entry, database) else { return false }
            messages.append(message)
        }
        session.cache = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if useV2 { Self.linkTurns(&messages) }
        session.messages = messages

        let parts = { (message: Message) in useV2 ? self.v2Parts(of: message, database) : self.parts(of: message.id, database) }
        let newest = messages.first
        session.openParts = newest.flatMap { $0.role == .assistant && $0.completed == nil ? parts($0) : nil }
        if let measured = messages.first(where: { $0.role == .assistant && $0.completed != nil && !$0.failed && $0.generated > 0 }) {
            if session.speed?.messageID != measured.id || session.speed?.updated != measured.updated {
                session.speed = (measured.id, measured.updated, parts(measured).flatMap { useV2 ? v2Measurement(measured, $0) : measurement(measured, $0) })
            }
        } else {
            session.speed = nil
        }
        session.summary = Summary(session)
        return true
    }

    /// One message's metadata; nil when the database refused the read or the row changed under it.
    private func message(_ entry: Entry, _ database: OpenCodeDatabase) -> Message? {
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

    /// A v2 row's metadata through SQLite's JSON functions; a prompt's row is never read. Nil when the database refused
    /// the read.
    private func v2Message(_ entry: Entry, _ database: OpenCodeDatabase) -> Message? {
        let role: Role = switch entry.type {
        case "user": .user
        case "assistant": .assistant
        case "idle": .idle
        default: .other
        }
        var message = Message(id: entry.id, created: entry.created, updated: entry.updated, role: role)
        guard role == .assistant || role == .idle else { return message }
        var found = false
        guard database.query("""
            SELECT json_extract(data, '$.time.completed'), json_extract(data, '$.time.streamed'), json_extract(data, '$.finish'),
                   coalesce(json_type(data, '$.error'), 'null') != 'null', json_extract(data, '$.model.id'), json_extract(data, '$.agent'),
                   json_extract(data, '$.tokens.output'), json_extract(data, '$.tokens.reasoning'), json_extract(data, '$.tokens.input'),
                   json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cache.write'), json_extract(data, '$.outcome'),
                   coalesce(json_type(data, '$.retry'), 'null') != 'null'
            FROM session_message WHERE id = ? AND \(database.sizeOfData) <= 16777216 AND json_valid(data)
            """, [entry.id], row: { row in
            found = true
            message.completed = Self.milliseconds(row.double(0))
            message.streamed = Self.milliseconds(row.double(1))
            message.finish = Self.text(row.text(2))
            message.failed = row.integer(3) == 1
            message.model = Self.text(row.text(4))
            message.agent = Self.text(row.text(5))
            message.generated = Self.count(row.double(6)) + Self.count(row.double(7))
            message.context = Self.count(row.double(8)) + Self.count(row.double(9)) + Self.count(row.double(10))
            message.outcome = Self.text(row.text(11))
            message.retried = row.integer(12) == 1
        }) else { return nil }
        if !found, role == .assistant {
            message.failed = true
            message.completed = entry.updated
        }
        return message
    }

    /// v2 rows name no parent: a prompt opens a turn when none is open (idle markers close one; without them every
    /// prompt opens its own), and the turn's messages point at it, as v1's `parentID` does. `messages` is newest first.
    private static func linkTurns(_ messages: inout [Message]) {
        let marked = messages.contains { $0.role == .idle }
        var opener: String?
        for index in messages.indices.reversed() {
            switch messages[index].role {
            case .user:
                if opener == nil || !marked { opener = messages[index].id }
                messages[index].parentID = opener
            case .assistant: messages[index].parentID = opener
            case .idle: opener = nil
            case .other: break
            }
        }
    }

    private func parts(of message: String, _ database: OpenCodeDatabase) -> [Part]? {
        var parts: [Part] = []
        guard database.query("SELECT time_updated, CASE WHEN \(database.sizeOfData) <= 262144 THEN data END FROM part WHERE message_id = ? ORDER BY id",
                             [message], row: { row in
            if let updated = row.date(0) { parts.append(Part(updated: updated, body: row.text(1))) }
        }) else { return nil }
        return parts
    }

    /// A v2 step's `content` items, in order: type, tool name and status, a tool's execution start and a reasoning end.
    private func v2Parts(of message: Message, _ database: OpenCodeDatabase) -> [Part]? {
        var parts: [Part] = []
        guard database.query("""
            SELECT json_extract(value, '$.type'), json_extract(value, '$.name'), json_extract(value, '$.state.status'),
                   json_extract(value, '$.time.ran'), json_extract(value, '$.time.completed')
            FROM session_message, json_each(session_message.data, '$.content')
            WHERE session_message.id = ? AND \(database.sizeOfData) <= 16777216 AND json_valid(session_message.data)
            ORDER BY json_each.key
            """, [message.id], row: { row in
            parts.append(Part(updated: message.updated, type: Self.text(row.text(0)), tool: Self.text(row.text(1)),
                              status: Self.text(row.text(2)), toolStart: Self.milliseconds(row.double(3)), end: Self.milliseconds(row.double(4))))
        }) else { return nil }
        return parts
    }

    /// Output + reasoning over created → last generated part; nil when a part was unreadable or no time was recorded.
    private func measurement(_ message: Message, _ parts: [Part]) -> TokenSpeedMeasurement? {
        guard !parts.contains(where: { !$0.readable }) else { return nil }
        let ends = parts.compactMap { part -> Date? in
            switch part.type {
            case "text", "reasoning": return part.end ?? part.updated
            case "tool": return part.toolStart
            default: return nil
            }
        }
        return speed(message, end: ends.max(), retried: parts.contains { $0.type == "retry" })
    }

    /// v2: output + reasoning over created → the stream's recorded end; else the step's end when it ran no tool; else the
    /// last tool's execution start (or a reasoning end) when a tool came last. Text carries no time.
    private func v2Measurement(_ message: Message, _ parts: [Part]) -> TokenSpeedMeasurement? {
        let end: Date?
        if let streamed = message.streamed { end = streamed }
        else if !parts.contains(where: { $0.type == "tool" }) { end = message.completed }
        else if parts.last?.type == "tool" {
            end = parts.compactMap { $0.type == "tool" ? $0.toolStart : $0.type == "reasoning" ? $0.end : nil }.max()
        } else { end = nil }
        return speed(message, end: end, retried: message.retried)
    }

    private func speed(_ message: Message, end: Date?, retried: Bool) -> TokenSpeedMeasurement? {
        guard let completed = message.completed, let end else { return nil }
        let milliseconds = end.timeIntervalSince(message.created) * 1_000
        guard milliseconds.isFinite, milliseconds > 0 else { return nil }
        var reading = TelemetryReading(provider: .opencode, at: completed)
        reading.model = message.model
        reading.outputTokens = message.generated
        reading.requestDurationMs = milliseconds.rounded()
        reading.requestDurationIncludesRetries = retried
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
            reading.clientName = clientName
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
    /// its `isDefaultTitle`) is no title, nor is a title MiMo Code marks `title_source = 'fallback'` (dropped when listed).
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
        guard let number = (value as? NSNumber)?.doubleValue ?? (value as? Double), number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number / 1_000)
    }

    fileprivate static func count(_ value: Any?) -> Int {
        guard let number = (value as? NSNumber)?.doubleValue ?? (value as? Double), number.isFinite, number > 0 else { return 0 }
        return Int(min(number, Double(Int32.max)))
    }
}

// MARK: - Model

/// The schema a pass reads, from `PRAGMA table_info`: which session tables and message stores exist, and the columns
/// that differ between OpenCode's versions and the apps built on it.
private struct Schema {
    private var columns: [String: Set<String>] = [:]

    /// Nil when the database refused the read.
    init?(_ database: OpenCodeDatabase) {
        for table in ["session_v2", "session", "message", "part", "session_message"] {
            var names = Set<String>()
            guard database.query("PRAGMA table_info(\(table))", row: { row in if let name = row.text(1) { names.insert(name) } }) else { return nil }
            if !names.isEmpty { columns[table] = names }
        }
    }

    /// `session_v2` first: a database migrated to v2 keeps the v1 `session` table beside it.
    var sessionTables: [String] { ["session_v2", "session"].filter { columns[$0]?.isSuperset(of: ["id", "time_updated"]) == true } }
    var hasV1: Bool { columns["message"] != nil && columns["part"] != nil }
    var hasV2: Bool { columns["session_message"] != nil }
    /// MiMo Code keeps its in-session subagent threads beside the main one (`agent_id`); only the main thread is read.
    var mainThread: String { columns["message"]?.contains("agent_id") == true ? " AND agent_id = 'main'" : "" }

    /// id, parent, directory, agent, model, updated, title (bounded: a generated or renamed one is short), title source.
    func sessionColumns(_ table: String) -> String {
        let has = columns[table] ?? []
        func column(_ name: String, _ expression: String? = nil) -> String { has.contains(name) ? expression ?? name : "NULL" }
        return "id, \(column("parent_id")), \(column("directory")), \(column("agent")), \(column("model")), time_updated, "
            + "\(column("title", "substr(title, 1, 1024)")), \(column("title_source")) FROM \(table)"
    }

    /// Older schemas lack `time_archived`.
    func unarchived(_ table: String) -> String { columns[table]?.contains("time_archived") == true ? "time_archived IS NULL" : "1" }
}

private struct Listed {
    let id: String
    let parent: String?
    let directory: String?
    let agent: String?
    let model: String?
    var updated: Date
    let title: String?
}

/// A message row before its body is read; `type` is v2's role column.
private struct Entry {
    let id: String
    let created: Date
    let updated: Date
    let type: String?
}

/// `idle`: v2's marker that a turn ended, with its outcome.
private enum Role { case user, assistant, idle, other }

/// One message's metadata; never its text.
private struct Message {
    let id: String
    let created: Date
    let updated: Date
    var role: Role = .other
    var completed: Date?
    /// v2: when the provider's response ended, before tools settled.
    var streamed: Date?
    var finish: String?
    var failed = false
    /// v2: the step was retried (its duration then includes the retries).
    var retried = false
    /// v2 idle marker: succeeded, failed or interrupted.
    var outcome: String?
    var model: String?
    /// The prompt that opened the turn (v2: set by `linkTurns`).
    var parentID: String?
    var cwd: String?
    var agent: String?
    /// Output + reasoning tokens (OpenCode records them apart).
    var generated = 0
    /// Input + cache read + cache write of this request.
    var context = 0

    /// A message known only by its role (a body too large to load, or a v2 row read field by field).
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

    /// A v2 `content` item, read in SQL; it carries no time of its own, so `updated` is its message's.
    init(updated: Date, type: String?, tool: String?, status: String?, toolStart: Date?, end: Date?) {
        self.updated = updated
        readable = true
        self.type = type
        self.tool = tool
        self.status = status
        self.toolStart = toolStart
        self.end = end
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
    /// Whether its messages are read from the v2 store; switching stores drops the cache.
    var v2 = false
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
            // A v2 prompt sent while a turn runs joins it.
            let turn = turn(of: newest.parentID ?? newest.id)
            open = true
            state = .working
            startedAt = turn?.start ?? newest.created
            turnOutput = turn?.output ?? 0
        case .assistant:
            if newest.completed == nil {
                open = true
                state = .working
                let parts = session.openParts ?? []
                // v1 tools are pending or running; v2's are streaming (dev builds: pending) or running.
                let running = parts.filter { $0.type == "tool" && ["pending", "streaming", "running"].contains($0.status) }
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
        case .idle:
            state = newest.outcome == "succeeded" ? .complete : newest.outcome == nil ? .idle : .interrupted
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

    /// `immutable` opens the file as a snapshot (`?immutable=1`): for a WAL database whose writer quit and removed its
    /// `-wal`/`-shm`, which a read-only connection cannot recreate. Later writes are not seen, so reopen on a changed stamp.
    init?(path: String, immutable: Bool = false) {
        var connection: OpaquePointer?
        let name = immutable ? "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1" : path
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | (immutable ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(name, &connection, flags, nil) == SQLITE_OK, let connection else {
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
