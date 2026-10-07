import Foundation

extension TokenLogFormat {
    /// Cursor agent transcripts under `projects/<slug>/agent-transcripts/`: `<id>/<id>.jsonl` (older builds `<id>.jsonl` or a
    /// `.txt`), and subagents in `<parent>/subagents/<id>.jsonl`.
    static let cursor = TokenLogFormat(files: { roots, discovery in
        var main: [URL] = []
        var subagents: [URL] = []
        for project in roots.flatMap(discovery.children) where discovery.isFolder(project) {
            for entry in discovery.children(project.appendingPathComponent("agent-transcripts")) {
                guard discovery.isFolder(entry) else {
                    if CursorLog.isTranscriptName(entry.lastPathComponent) { main.append(entry) }
                    continue
                }
                let id = entry.lastPathComponent
                for child in discovery.children(entry) {
                    let name = child.lastPathComponent
                    if name == id + ".jsonl" || name == id + ".txt" { main.append(child) }
                    else if name == "subagents" { subagents.append(contentsOf: discovery.children(child).filter { $0.pathExtension == "jsonl" }) }
                }
            }
        }
        return discovery.recent(main) + discovery.recent(subagents)
    }, isLog: CursorLog.isTranscript, open: { CursorLogReader(url: $0) })
}

/// Cursor (the IDE's agent and the cursor-agent CLI) writes one transcript per conversation, keyed by its composer id.
/// - JSONL records `{role, message: {content: [text | tool_use]}}` and `{type: "turn_ended", status}`; no times, ids,
///   model or tokens. The person's message opens a turn, an assistant step with tool uses runs them until the next step,
///   `turn_ended` closes it (`success` completes it, anything else interrupts it). A legacy `.txt` transcript marks blocks
///   with `user:` / `assistant:` lines and `[Tool call] <name>` / `[Tool result]`; it has no end record, so assistant text
///   after the last tool completes the turn (a later block reopens it).
/// - Times: records carry none, so lines read together take the file's modification time; on the first read only the
///   last line does (earlier lines are of unknown age). Cursor prefixes newer prompts with `<timestamp>Friday, Jul 17,
///   2026, 12:26 AM (UTC+9)</timestamp>`, which dates the turn's start to the minute.
/// - The IDE's `globalStorage/state.vscdb` (read-only, re-queried when its file or WAL changes) adds per composer: the
///   title Cursor generated or the person gave (`name`; never the prompt), a blocking pending action (an approval:
///   `input`), the workspace folder, the model of the latest request (`default` is Auto and not a model), the context
///   occupied (`contextTokensUsed` of `contextTokenLimit`), the subagent type and its update time (liveness only).
/// - The cursor-agent CLI's `chats/<hash>/<id>/store.db` names the model (`meta` row `lastUsedModel`).
/// - Project: the IDE's worktree or workspace folder; else the transcript folder's slug (the path with every separator
///   as `-`) matched against existing folders.
/// - Tokens and speed: Cursor keeps no reliable token counts locally, so no output, turn total or speed is reported.
enum CursorLog {
    /// `<id>.jsonl` / `<id>.txt` directly in `agent-transcripts`.
    static func isTranscriptName(_ name: String) -> Bool { name.hasSuffix(".jsonl") || name.hasSuffix(".txt") }

    /// A path `files` would list: `agent-transcripts/<id>.(jsonl|txt)`, `agent-transcripts/<id>/<id>.(jsonl|txt)` or
    /// `agent-transcripts/<parent>/subagents/<id>.jsonl`.
    static func isTranscript(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let marker = parts.lastIndex(of: "agent-transcripts"), let name = parts.last, isTranscriptName(String(name)) else { return false }
        let id = name.hasSuffix(".jsonl") ? name.dropLast(6) : name.dropLast(4)
        switch parts.count - marker {
        case 2: return true
        case 3: return parts[marker + 1] == id
        case 4: return parts[marker + 2] == "subagents" && name.hasSuffix(".jsonl")
        default: return false
        }
    }

    /// Cursor's tool names; anything else falls back to the shared table.
    static func category(_ name: String) -> ToolCategory {
        switch name {
        case "Shell", "Terminal", "run_terminal_cmd": return .command
        case "Read", "Write", "StrReplace", "Delete", "Glob", "Grep", "SemanticSearch", "ReadLints", "EditNotebook", "ApplyPatch",
             "LS", "read_file", "edit_file", "grep_search", "file_search", "codebase_search", "list_dir": return .file
        case "WebSearch", "WebFetch", "web_search": return .web
        case "Task", "Subagent": return .agent
        case "AskQuestion": return .question
        default: return TokenLogParser.category(name)
        }
    }

    /// A prompt's leading `<timestamp>…</timestamp>` tag (minute precision, local time with its UTC offset).
    static func promptTime(_ text: String) -> Date? {
        let head = text.prefix(160)
        guard head.hasPrefix("<timestamp>"), let close = head.range(of: "</timestamp>"),
              let zone = head.range(of: " (UTC", range: head.startIndex..<close.lowerBound) else { return nil }
        let local = String(head[head.index(head.startIndex, offsetBy: 11)..<zone.lowerBound])
        var offset = String(head[zone.upperBound..<close.lowerBound])
        guard offset.hasSuffix(")") else { return nil }
        offset.removeLast()
        var seconds = 0
        if !offset.isEmpty {
            guard let sign = offset.first, sign == "+" || sign == "-" else { return nil }
            let parts = offset.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let hours = Int(parts[0]), (0...14).contains(hours) else { return nil }
            let minutes = parts.count == 2 ? Int(parts[1]) : 0
            guard let minutes, (0...59).contains(minutes) else { return nil }
            seconds = (hours * 3_600 + minutes * 60) * (sign == "-" ? -1 : 1)
        }
        guard let timeZone = TimeZone(secondsFromGMT: seconds) else { return nil }
        promptFormatter.timeZone = timeZone
        return promptFormatter.date(from: local)
    }

    private static let promptFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMM d, yyyy, h:mm a"
        return formatter
    }()

    /// A model name; Cursor's `default` (Auto) names none.
    static func model(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "default", value.count <= 128 else { return nil }
        return value
    }
}

final class CursorLogReader: TokenLogReader {
    private enum Event {
        case prompt(Date?), step(tools: [String?]), results, ended(success: Bool)
        case legacyUser, legacyAssistant, legacyTool(String), legacyResult, legacyText
    }

    private let tail: LogLineTail
    private let sessionID: String
    private let parentID: String?
    private let legacy: Bool
    /// The `projects/<slug>` folder name.
    private let slug: String?
    private let ideStore: CursorIDEStore
    private let chatFolders: [URL]
    /// The CLI's `agent-cli-state.json`, which names the folders it ran in.
    private let cliState: URL?
    private let home: String
    private var turn = LogTurnState()
    private var tools: [String] = []
    private var toolCount = 0
    /// Legacy transcripts: the block now being written is the assistant's.
    private var legacyAssistant = false
    private var composer: CursorComposer?
    private var project: CursorProject.Resolved?
    private var chatStore: URL?
    private var chatSearchedAt: Date?
    private var chatSignature: [Int64]?
    private var chatModel: String?

    init(url: URL) {
        tail = LogLineTail(url: url)
        legacy = url.pathExtension == "txt"
        sessionID = url.deletingPathExtension().lastPathComponent
        let parts = url.pathComponents
        let marker = parts.lastIndex(of: "agent-transcripts")
        parentID = marker.flatMap { parts.count - $0 == 4 && parts[$0 + 2] == "subagents" ? parts[$0 + 1] : nil }
        slug = marker.flatMap { $0 >= 1 ? parts[$0 - 1] : nil }
        // <cursor dir>/projects/<slug>/agent-transcripts/…; ~/.cursor names the home whose IDE storage goes with it.
        let cursorDir = marker.map { URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<max(1, $0 - 2)]))) }
        let home = cursorDir.flatMap { $0.lastPathComponent == ".cursor" ? $0.deletingLastPathComponent() : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.home = home.path
        ideStore = CursorIDEStore.at(home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"))
        chatFolders = [cursorDir?.appendingPathComponent("chats"), home.appendingPathComponent(".config/cursor/chats")].compactMap { $0 }
        cliState = cursorDir?.appendingPathComponent("agent-cli-state.json")
    }

    func isRecent(at now: Date) -> Bool { turn.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] {
        let cwd = composer?.cwd ?? project?.path
        guard var reading = turn.reading(source: .cursor, id: id, model: composer?.model ?? chatModel, cwd: cwd, now: now) else { return [] }
        if composer?.cwd == nil {
            reading.project = project?.name ?? slug
            reading.projectPath = project?.exists == true ? project?.path : nil
        }
        reading.toolCategory = reading.toolName.map(CursorLog.category) ?? reading.toolCategory
        reading.sessionID = sessionID
        if let parentID {
            reading.isSubagent = true
            reading.parentSessionID = parentID
            reading.agentID = sessionID
            reading.agentRole = TokenLogParser.label(composer?.subagentType)
        }
        reading.title = composer?.title
        reading.context = composer?.context
        reading.currentTurnOutputTokens = nil
        return [reading]
    }

    func read(tailLimit: Int, now: Date) {
        turn.clamp(to: now.addingTimeInterval(5))
        let initial = tail.modified == nil
        var events: [Event] = []
        tail.read(tailLimit: tailLimit, reset: {
            turn = LogTurnState()
            tools.removeAll()
            legacyAssistant = false
        }) { line in
            if let event = legacy ? Self.legacyEvent(line) : Self.event(line) { events.append(event) }
        }
        if !events.isEmpty, let modified = tail.modified {
            let written = min(modified, now.addingTimeInterval(5))
            for (index, event) in events.enumerated() {
                apply(event, at: initial && index < events.count - 1 ? nil : written, written: written)
            }
            if legacy, legacyAssistant, case .legacyText = events[events.count - 1], !turn.hasPendingTools {
                turn.close(.complete, at: written, model: nil)
            }
        }
        enrich(now: now)
    }

    private static func event(_ data: Data) -> Event? {
        guard let record = LogFields.object(data) else { return nil }
        if record["type"] as? String == "turn_ended" { return .ended(success: record["status"] as? String == "success") }
        guard let message = record["message"] as? [String: Any] else { return nil }
        let content = message["content"]
        let blocks = content as? [[String: Any]] ?? []
        switch record["role"] as? String ?? message["role"] as? String {
        case "user":
            if !blocks.isEmpty, blocks.allSatisfy({ $0["type"] as? String == "tool_result" }) { return .results }
            let texts = content is String ? [content as? String] : blocks.filter { $0["type"] as? String == "text" }.map { $0["text"] as? String }
            return .prompt(texts.lazy.compactMap { $0.flatMap(CursorLog.promptTime) }.first)
        case "assistant":
            return .step(tools: blocks.filter { $0["type"] as? String == "tool_use" }.map { LogFields.text($0["name"]) })
        default:
            return nil
        }
    }

    private static func legacyEvent(_ data: Data) -> Event? {
        var right = Substring(String(decoding: data, as: UTF8.self))
        while right.last?.isWhitespace == true { right.removeLast() }
        if right == "user:" { return .legacyUser }
        if right == "assistant:" { return .legacyAssistant }
        let trimmed = right.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("[Tool call] ") { return .legacyTool(String(trimmed.dropFirst(12).prefix(128))) }
        if trimmed.hasPrefix("[Tool result]") { return .legacyResult }
        return .legacyText
    }

    /// `date` is nil for a line of unknown age (before the last line of the first read).
    private func apply(_ event: Event, at date: Date?, written: Date) {
        turn.logged(date)
        switch event {
        case .prompt(let stamped):
            finishTools(at: date)
            turn.begin(at: stamped.map { min($0, written) } ?? date)
        case .step(let names):
            turn.resume(at: date)
            finishTools(at: date)
            if names.isEmpty { turn.setState(.working, at: date) }
            for name in names { startTool(name, at: date) }
        case .results:
            finishTools(at: date)
        case .ended(let success):
            turn.resume(at: date)
            tools.removeAll()
            turn.close(success ? .complete : .interrupted, at: date, model: nil)
        case .legacyUser:
            legacyAssistant = false
            finishTools(at: date)
            turn.begin(at: date)
        case .legacyAssistant:
            legacyAssistant = true
            turn.resume(at: date)
            turn.setState(turn.hasPendingTools ? .tool : .working, at: date)
        case .legacyTool(let name):
            turn.resume(at: date)
            startTool(name, at: date)
        case .legacyResult:
            finishTools(at: date)
        case .legacyText:
            turn.touch(date)
        }
    }

    /// Tool uses carry no ids; the next step or result record means they returned.
    private func startTool(_ name: String?, at date: Date?) {
        toolCount += 1
        let id = "cursor-tool-\(toolCount)"
        tools.append(id)
        turn.startTool(id, name: name, at: date)
    }

    private func finishTools(at date: Date?) {
        for id in tools { turn.finishTool(id, at: date) }
        tools.removeAll()
    }

    private func enrich(now: Date) {
        composer = ideStore.composer(sessionID, now: now)
        turn.logged(composer?.updated.map { min($0, now.addingTimeInterval(5)) })
        if composer?.pending == true { turn.startRequest("cursor-pending-action", at: nil) } else { turn.finishRequest("cursor-pending-action") }
        if composer?.cwd == nil, let slug {
            let recorded = ideStore.workspaces + (cliState.map { CursorProject.cliWorkspaces($0, home: home) } ?? [])
            project = CursorProject.match(slug, recorded).map { CursorProject.Resolved(path: $0, exists: true) }
                ?? CursorProject.resolve(slug, now: now)
        }
        if composer?.model == nil { readChatModel(now: now) }
    }

    /// The cursor-agent CLI's `chats/<hash>/<id>/store.db`: `meta['0']` is hex-encoded JSON whose `lastUsedModel` names the
    /// model. Only that field is read; the store is looked for again every 5 minutes until found.
    private func readChatModel(now: Date) {
        if chatStore == nil {
            guard chatSearchedAt.map({ now.timeIntervalSince($0) >= 300 || now < $0 }) ?? true else { return }
            chatSearchedAt = now
            chatStore = chatFolders.lazy.flatMap { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).lazy.map {
                    folder.appendingPathComponent($0).appendingPathComponent(self.sessionID).appendingPathComponent("store.db")
                }
            }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let chatStore, let signature = OpenCodeDatabase.signature(chatStore.path), signature != chatSignature,
              let database = CursorIDEStore.open(chatStore.path) else { return }
        var value: String?
        guard database.query("SELECT CAST(value AS TEXT) FROM meta WHERE key = '0'", row: { value = $0.text(0) }) else { return }
        chatSignature = signature
        guard let value, value.utf8.count <= 1_048_576, let data = Self.hex(value),
              let meta = LogFields.object(data) else { return }
        chatModel = CursorLog.model(meta["lastUsedModel"] as? String)
    }

    private static func hex(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var data = Data(capacity: bytes.count / 2)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }
}

/// What the IDE's database says about one composer. Only metadata; never message text.
struct CursorComposer {
    var title: String?
    var model: String?
    var cwd: String?
    var pending = false
    var updated: Date?
    var subagentType: String?
    var context: TokenContextUsage?
}

/// The IDE's `state.vscdb`, shared by every transcript reader of one home. Re-queried when the database or its WAL changed
/// (at most once per sample), and then only for composers a reader asked about within 10 minutes.
/// - Headers: the `composerHeaders` table (current builds), else the `composer.composerHeaders` JSON in `ItemTable`.
/// - `composerData:<id>` in `cursorDiskKV` (model, worktree, context) is parsed again only when its header moved.
final class CursorIDEStore {
    private static var stores: [String: CursorIDEStore] = [:]

    static func at(_ url: URL) -> CursorIDEStore {
        if let store = stores[url.path] { return store }
        let store = CursorIDEStore(path: url.path)
        stores[url.path] = store
        return store
    }

    /// Read-only; as an immutable snapshot when Cursor quit and took its `-wal`/`-shm` along (a read-only connection
    /// cannot recreate them). The snapshot misses later writes, so it is opened again whenever the stamp changes.
    static func open(_ path: String) -> OpenCodeDatabase? {
        OpenCodeDatabase(path: path, immutable: !FileManager.default.fileExists(atPath: path + "-wal"))
    }

    private let path: String
    private var signature: [Int64]?
    private var sampledAt: Date?
    private var wanted: [String: Date] = [:]
    private var composers: [String: CursorComposer] = [:]
    /// The header stamp each composer's `composerData` was read at.
    private var dataStamps: [String: String] = [:]
    /// Every composer's workspace folder (at most 512): what a transcript's slug is matched against.
    private(set) var workspaces: [String] = []

    private init(path: String) { self.path = path }

    func composer(_ id: String, now: Date) -> CursorComposer? {
        let known = wanted[id] != nil
        wanted[id] = now
        if sampledAt != now || !known {
            sampledAt = now
            wanted = wanted.filter { now.timeIntervalSince($0.value) <= 600 }
            refresh(now: now, onlyNew: known ? nil : id)
        }
        return composers[id]
    }

    /// `onlyNew`: a composer asked about for the first time, queried alone when nothing else changed.
    private func refresh(now: Date, onlyNew: String?) {
        guard let current = OpenCodeDatabase.signature(path) else {
            signature = nil
            composers.removeAll()
            dataStamps.removeAll()
            workspaces.removeAll()
            return
        }
        let ids: [String]
        if current != signature { ids = Array(wanted.keys) } else if let onlyNew { ids = [onlyNew] } else { return }
        guard !ids.isEmpty, let database = Self.open(path), database.execute("BEGIN") else { return }
        defer { _ = database.execute("COMMIT") }
        var tables = Set<String>()
        guard database.query("SELECT name FROM sqlite_master WHERE type = 'table'", row: { if let name = $0.text(0) { tables.insert(name) } }),
              let headers = headers(ids, tables, database) else { return }
        if current != signature {
            guard let folders = workspaces(tables, database) else { return }
            workspaces = folders
        }
        for id in ids {
            var composer = composers[id] ?? CursorComposer()
            let header = headers[id]
            composer.title = header?.title
            composer.pending = header?.pending ?? false
            composer.updated = header?.updated
            composer.subagentType = header?.subagentType
            let stamp = header?.stamp ?? ""
            if header == nil || dataStamps[id] != stamp {
                var data: (model: String?, worktree: String?, context: TokenContextUsage?) = (nil, nil, nil)
                if tables.contains("cursorDiskKV") {
                    guard let read = composerData(id, database) else { return }
                    data = read
                }
                dataStamps[id] = stamp
                composer.model = data.model
                composer.context = data.context
                composer.cwd = data.worktree ?? header?.workspace
            }
            composers[id] = header == nil && composer.model == nil && composer.cwd == nil ? nil : composer
        }
        signature = current
    }

    /// Nil when the database refused the read.
    private func workspaces(_ tables: Set<String>, _ database: OpenCodeDatabase) -> [String]? {
        let path = "substr(json_extract(%@, '$.workspaceIdentifier.uri.fsPath'), 1, 4096)"
        let sql: String
        if tables.contains("composerHeaders") {
            sql = "SELECT DISTINCT \(path.replacingOccurrences(of: "%@", with: "value")) FROM composerHeaders LIMIT 512"
        } else if tables.contains("ItemTable") {
            sql = "SELECT DISTINCT \(path.replacingOccurrences(of: "%@", with: "j.value")) FROM ItemTable, "
                + "json_each(CAST(ItemTable.value AS TEXT), '$.allComposers') j WHERE ItemTable.key = 'composer.composerHeaders' LIMIT 512"
        } else {
            return []
        }
        var found: [String] = []
        return database.query(sql, row: { if let folder = LogFields.text($0.text(0)) { found.append(folder) } }) ? found : nil
    }

    private struct Header {
        var title: String?
        var pending: Bool
        var workspace: String?
        var updated: Date?
        var subagentType: String?
        var stamp: String
    }

    /// The `composerHeaders` table of current builds, else the `composer.composerHeaders` JSON in `ItemTable`. Nil when the
    /// database refused the read.
    private func headers(_ ids: [String], _ tables: Set<String>, _ database: OpenCodeDatabase) -> [String: Header]? {
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        func fields(_ value: String) -> String {
            "substr(json_extract(\(value), '$.name'), 1, 1024), json_extract(\(value), '$.hasBlockingPendingActions'), "
                + "substr(json_extract(\(value), '$.workspaceIdentifier.uri.fsPath'), 1, 4096)"
        }
        var found: [String: Header] = [:]
        let collect: (OpenCodeDatabase.Row) -> Void = { row in
            guard let id = row.text(0) else { return }
            let updated = row.integer(4)
            found[id] = Header(title: SessionTitle.clean(row.text(1)), pending: row.integer(2) == 1, workspace: LogFields.text(row.text(3)),
                               updated: updated.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1_000) : nil },
                               subagentType: row.text(5), stamp: "\(updated ?? 0)|\(row.double(6) ?? -1)")
        }
        if tables.contains("composerHeaders") {
            let sql = "SELECT composerId, \(fields("value")), lastUpdatedAt, substr(subagentTypeName, 1, 64), "
                + "json_extract(value, '$.contextUsagePercent') FROM composerHeaders WHERE composerId IN (\(marks))"
            return database.query(sql, ids, row: collect) ? found : nil
        }
        guard tables.contains("ItemTable") else { return [:] }
        let sql = "SELECT json_extract(j.value, '$.composerId'), \(fields("j.value")), json_extract(j.value, '$.lastUpdatedAt'), "
            + "substr(json_extract(j.value, '$.subagentTypeName'), 1, 64), json_extract(j.value, '$.contextUsagePercent') "
            + "FROM ItemTable, json_each(CAST(ItemTable.value AS TEXT), '$.allComposers') j "
            + "WHERE ItemTable.key = 'composer.composerHeaders' AND json_extract(j.value, '$.composerId') IN (\(marks))"
        return database.query(sql, ids, row: collect) ? found : nil
    }

    /// The model of the latest request (the newest user bubble's, else the composer's setting), the worktree and the
    /// context occupied. Nil when the database refused the read; empty values when there is no such composer.
    private func composerData(_ id: String, _ database: OpenCodeDatabase) -> (model: String?, worktree: String?, context: TokenContextUsage?)? {
        var result: (model: String?, worktree: String?, context: TokenContextUsage?) = (nil, nil, nil)
        let sql = """
            SELECT json_extract(v, '$.modelConfig.modelName'), json_extract(v, '$.contextTokensUsed'), json_extract(v, '$.contextTokenLimit'),
                   json_extract(v, '$.lastUpdatedAt'), substr(json_extract(v, '$.gitWorktree.worktreePath'), 1, 4096),
                   (SELECT json_extract(CAST(b.value AS TEXT), '$.modelInfo.modelName') FROM cursorDiskKV b
                    WHERE b.key = 'bubbleId:' || ?1 || ':' || (SELECT json_extract(h.value, '$.bubbleId')
                        FROM json_each(v, '$.fullConversationHeadersOnly') h WHERE json_extract(h.value, '$.type') = 1 ORDER BY h.key DESC LIMIT 1))
            FROM (SELECT CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key = 'composerData:' || ?1)
            """
        guard database.query(sql, [id], row: { row in
            result.model = CursorLog.model(row.text(5)) ?? CursorLog.model(row.text(0))
            result.worktree = LogFields.text(row.text(4))
            if let used = row.integer(1), used > 0, let updated = row.integer(3), updated > 0 {
                result.context = TokenContextUsage(usedTokens: Int(used), windowTokens: row.integer(2).flatMap { $0 > 0 ? Int($0) : nil },
                                                   recordedAt: Date(timeIntervalSince1970: Double(updated) / 1_000))
            }
        }) else { return nil }
        return result
    }
}

/// The folder a `projects/<slug>` name stands for. Cursor writes the path with every separator (and `.`, `_`, spaces) as
/// `-`, so the slug is lossy. First it is matched against folders Cursor itself recorded (`match`: every IDE composer's
/// workspace and the CLI's `agent-cli-state.json`), which opens no other folder. Else it is matched against existing
/// folders from the root down (`decode`); a unique full match is the project. The walk never enters a folder macOS
/// guards with a privacy prompt (a home's Desktop, Documents, Downloads, Library, Pictures, Movies and Music, and
/// mounted volumes). When nothing matches, the deepest folder reached plus the rest of the slug (joined with `-`) names
/// it, so a deleted temporary folder still shows its own name; a slug matching no folder at all (`empty-window`, a
/// window number) is shown as is.
enum CursorProject {
    struct Resolved: Equatable {
        var path: String
        var exists: Bool
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Resolutions by slug for 10 minutes; tracker queue only.
    private static var cache: [String: (value: Resolved?, at: Date)] = [:]
    private static var cliStates: [String: (stamp: String, folders: [String])] = [:]
    private static let guarded: Set<String> = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music"]

    /// The one recorded folder whose path reads as `slug`; nil when none or several do.
    static func match(_ slug: String, _ folders: [String]) -> String? {
        let tokens = slug.split(separator: "-").map(String.init)
        guard !tokens.isEmpty else { return nil }
        // macOS's /var and /tmp live in /private; Cursor names them without it (`var-folders-…`).
        let found = Set(folders.map { $0.hasPrefix("/private/") ? String($0.dropFirst(8)) : $0 }.filter { Self.tokens($0).contains(tokens) })
        return found.count == 1 ? found.first : nil
    }

    /// `workerIdsByDisplayName` keys of the CLI's state file ("~/Desktop/GitHub/app @ host"), re-read when its stamp changes.
    static func cliWorkspaces(_ url: URL, home: String) -> [String] {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return [] }
        let stamp = "\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        if let cached = cliStates[url.path], cached.stamp == stamp { return cached.folders }
        var folders: [String] = []
        if info.st_size <= 1_048_576, let data = try? Data(contentsOf: url),
           let names = (LogFields.object(data)?["workerIdsByDisplayName"] as? [String: Any])?.keys {
            for name in names.prefix(512) {
                var folder = name
                if let at = folder.range(of: " @ ", options: .backwards) { folder = String(folder[..<at.lowerBound]) }
                if folder == "~" || folder.hasPrefix("~/") { folder = home + folder.dropFirst() }
                if folder.hasPrefix("/") { folders.append(folder) }
            }
        }
        cliStates[url.path] = (stamp, folders)
        return folders
    }

    static func resolve(_ slug: String, now: Date, root: String = "/") -> Resolved? {
        let key = root + "\n" + slug
        if let cached = cache[key], abs(now.timeIntervalSince(cached.at)) < 600 { return cached.value }
        let value = decode(slug, root: root)
        if cache.count > 512 { cache.removeAll() }
        cache[key] = (value, now)
        return value
    }

    static func decode(_ slug: String, root: String = "/") -> Resolved? {
        let tokens = slug.split(separator: "-").map(String.init)
        guard !tokens.isEmpty else { return nil }
        var matches: [String] = []
        var deepest: (path: String, consumed: Int)?
        var budget = 256
        func walk(_ folder: String, _ consumed: Int) {
            guard matches.count < 2, budget > 0 else { return }
            if consumed == tokens.count { matches.append(folder); return }
            if consumed > (deepest?.consumed ?? 0) { deepest = (folder, consumed) }
            budget -= 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            var candidates: [(name: String, count: Int)] = []
            for name in names {
                for parts in Self.tokens(name) where !parts.isEmpty && consumed + parts.count <= tokens.count
                    && zip(parts, tokens[consumed...]).allSatisfy({ $0 == $1 }) {
                    candidates.append((name, parts.count))
                    break
                }
            }
            for candidate in candidates.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }) {
                let path = (folder as NSString).appendingPathComponent(candidate.name)
                if folder == "/Volumes" || (folder as NSString).deletingLastPathComponent == "/Users" && guarded.contains(candidate.name) {
                    if consumed + candidate.count > (deepest?.consumed ?? 0) { deepest = (path, consumed + candidate.count) }
                    continue
                }
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { continue }
                walk(path, consumed + candidate.count)
            }
        }
        walk(root, 0)
        if let match = matches.first { return Resolved(path: match, exists: true) }
        guard let deepest else { return nil }
        return Resolved(path: (deepest.path as NSString).appendingPathComponent(tokens[deepest.consumed...].joined(separator: "-")), exists: false)
    }

    /// A folder name's slug tokens: split at every character other than an ASCII letter or digit, and (for names with
    /// other letters) at every character other than a letter or digit.
    private static func tokens(_ name: String) -> [[String]] {
        let ascii = name.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        let unicode = name.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return ascii == unicode ? [ascii] : [ascii, unicode]
    }
}
