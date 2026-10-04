import Foundation
import CoreFoundation

/// Passive, bounded log reader. It never changes either CLI's configuration or saves transcripts.
final class TokenTracker {
    private let home: URL
    private let clock: () -> Date
    private let initialTailBytes: Int
    private let discoveryInterval: TimeInterval
    private var lastDiscovery: Date?
    private var files: [String: TokenFileCursor] = [:]
    private let manager = FileManager.default
    static let recentOutputWindow: TimeInterval = 600

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         now: @escaping () -> Date = Date.init,
         initialTailBytes: Int = 1_048_576,
         discoveryInterval: TimeInterval = 5) {
        home = homeDirectory
        clock = now
        self.initialTailBytes = max(128, initialTailBytes)
        self.discoveryInterval = discoveryInterval
    }

    var watchedDirectories: [URL] {
        [home.appendingPathComponent(".codex/sessions"), home.appendingPathComponent(".claude/projects")]
    }

    /// File-system events name changed paths. A log that is not tracked yet triggers
    /// discovery on the next sample instead of waiting for the periodic rescan.
    func noteChanged(paths: [String]) {
        // Workflow journals and other side files under subagents/ are never tracked.
        func candidate(_ path: String) -> Bool {
            path.hasSuffix(".jsonl") && files[path] == nil
                && (!path.contains("/subagents/") || (path as NSString).lastPathComponent.hasPrefix("agent-"))
        }
        if paths.contains(where: candidate) { lastDiscovery = nil }
    }

    func sample() -> [TokenReading] {
        let now = clock()
        if lastDiscovery == nil || now.timeIntervalSince(lastDiscovery!) >= discoveryInterval {
            discover(now: now)
            lastDiscovery = now
        }
        for file in files.values { file.read(tailLimit: initialTailBytes) }
        return files.values.compactMap { file -> TokenReading? in
            let parser = file.parser
            guard parser.lastActivity != nil else { return nil }
            let completion = parser.completion
            let running = parser.isActive(at: now)
            let relative = file.url.path.hasPrefix(home.path + "/")
                ? String(file.url.path.dropFirst(home.path.count + 1)) : file.url.path
            var reading = TokenReading(source: parser.source, id: "\(parser.source.rawValue):\(relative)")
            reading.sessionID = parser.sessionID
            reading.parentSessionID = parser.parentSessionID
            reading.agentID = parser.agentID
            reading.project = parser.project
            reading.isSubagent = parser.isSubagent
            reading.model = parser.model ?? completion?.model
            reading.measurementModel = completion?.model
            reading.lastActivity = parser.lastActivity
            reading.lastLogAt = parser.lastLogAt
            reading.measurementAt = completion?.finishedAt ?? parser.lastActivity
            reading.active = running
            reading.activityState = parser.activityState(at: now)
            reading.currentTurnStartedAt = parser.currentTurnStartedAt
            reading.currentTurnOutputTokens = parser.currentTurnOutputTokens
            reading.lastOutputAt = parser.lastOutputAt
            reading.lastOutputDelta = parser.lastOutputDelta
            reading.recentOutputs = parser.recentOutputs.filter {
                let age = now.timeIntervalSince($0.at)
                return age >= -5 && age <= Self.recentOutputWindow
            }
            reading.sampledAt = now
            reading.sessionCount = 1
            reading.turnAverageTokensPerSecond = completion?.rate
            reading.lastOutputTokens = completion?.output ?? parser.latestOutput
            reading.quality = completion?.quality ?? "턴 시간 미확인 · 속도 대기"
            if running {
                reading.status = completion == nil ? "최근 활동 · 속도 기록 대기" : "최근 활동 · 이전 완료값"
            } else {
                reading.status = completion == nil ? "출력 기록 · 턴 시간 미확인" : "완료된 턴"
            }
            return reading
        }.sorted {
            if $0.active != $1.active { return $0.active }
            if $0.lastActivity != $1.lastActivity {
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
            return $0.id < $1.id
        }
    }

    private func discover(now: Date) {
        let roots: [(TokenSource, [URL])] = [
            (.codex, codexFiles()), (.claude, claudeFiles())
        ]
        var retained = Set<String>()
        for (source, urls) in roots {
            for url in urls {
                retained.insert(url.path)
                if files[url.path] == nil { files[url.path] = TokenFileCursor(url: url, source: source) }
            }
        }
        // A quiet session in a turn, or logged within the hour, is not evicted by a burst of
        // newer subagent logs; re-adding it later would restart from a bounded tail.
        for (path, cursor) in files.sorted(by: { $0.key < $1.key })
        where !retained.contains(path) && retained.count < 128 && cursor.parser.isRecent(at: now)
            && manager.fileExists(atPath: path) {
            retained.insert(path)
        }
        files = files.filter { retained.contains($0.key) }
    }

    private func children(_ directory: URL) -> [URL] {
        (try? manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private func recent(_ urls: [URL]) -> [URL] {
        urls.filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.prefix(32).map { $0.0 }
    }

    private func codexFiles() -> [URL] {
        // A resumed conversation stays in its original UTC date directory. Select by file
        // modification time across date directories, without reading transcript bodies here.
        let root = home.appendingPathComponent(".codex/sessions")
        var found: [URL] = []
        for year in children(root).filter({ Int($0.lastPathComponent) != nil }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            for month in children(year).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                for day in children(month).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                    found.append(contentsOf: children(day).filter { $0.pathExtension == "jsonl" })
                }
            }
        }
        return recent(found)
    }

    private func claudeFiles() -> [URL] {
        let root = home.appendingPathComponent(".claude/projects")
        var main: [URL] = []
        var subagents: [URL] = []
        for project in children(root) {
            let entries = children(project)
            main.append(contentsOf: entries.filter { $0.pathExtension == "jsonl" })
            for session in entries where session.pathExtension.isEmpty {
                subagents.append(contentsOf: claudeSubagentFiles(in: session.appendingPathComponent("subagents"), remainingDepth: 2))
            }
        }
        // Workflow agents create many files; they get their own cap so main sessions stay visible.
        return recent(main) + recent(subagents)
    }

    private func claudeSubagentFiles(in directory: URL, remainingDepth: Int) -> [URL] {
        let entries = children(directory)
        var found = entries.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
        if remainingDepth > 0 {
            for child in entries where child.pathExtension.isEmpty {
                found.append(contentsOf: claudeSubagentFiles(in: child, remainingDepth: remainingDepth - 1))
            }
        }
        return found
    }
}

private final class TokenFileCursor {
    let url: URL
    private(set) var parser: TokenLogParser
    private var offset: UInt64 = 0
    private var identity: String?
    private var initialized = false
    private var pending = Data()
    private var droppingLine = false
    private let maximumLineBytes = 1_048_576

    init(url: URL, source: TokenSource) {
        self.url = url
        parser = Self.parser(for: url, source: source)
    }

    /// Codex names each rollout after its own thread; a forked log also carries the parent's
    /// session_meta, so the filename decides which one is this log's identity.
    private static func parser(for url: URL, source: TokenSource) -> TokenLogParser {
        let name = url.deletingPathExtension().lastPathComponent
        let suffix = String(name.suffix(36))
        let ownSession = source == .codex && UUID(uuidString: suffix) != nil ? suffix.lowercased() : nil
        return TokenLogParser(source: source, isSubagent: source == .claude && url.path.contains("/subagents/"),
                              ownSessionID: ownSession)
    }

    func read(tailLimit: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        let currentIdentity = "\(attributes[.systemNumber] ?? 0)-\(attributes[.systemFileNumber] ?? 0)"
        if initialized && (identity != currentIdentity || size < offset) {
            offset = 0
            initialized = false
            pending.removeAll(keepingCapacity: false)
            droppingLine = false
            parser = Self.parser(for: url, source: parser.source)
        }
        // Unchanged logs are polled every tick; avoid reopening them.
        if initialized && size == offset { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        if !initialized {
            // Recover identity metadata missed by a tail. This bounded header never replays
            // token counts, lifecycle events, models or conversation content into parser state.
            if size > UInt64(tailLimit), let header = try? handle.read(upToCount: 65_536) {
                var start = header.startIndex
                while start < header.endIndex,
                      let newline = header[start...].firstIndex(of: 10) {
                    parser.consumeMetadata(Data(header[start..<newline]))
                    start = header.index(after: newline)
                }
            }
            if parser.source == .codex, size > UInt64(tailLimit) {
                restoreCodexMetadata(handle: handle, size: size)
            }
            offset = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
            droppingLine = offset > 0
            // An open Claude turn that began before the tail is read from its human input,
            // so the whole turn's output is counted rather than reported as unknown.
            if parser.source == .claude, offset > 0, let start = claudeTurnStart(handle: handle, size: size), start < offset {
                offset = start
                droppingLine = false
            }
            identity = currentIdentity
            initialized = true
        }
        guard size > offset else { return }
        // Bursts (large tool outputs, the initial turn replay) are caught up within one sample.
        var budget = 16_777_216 + tailLimit
        do {
            while offset < size, budget > 0 {
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: min(1_048_576, Int(min(size - offset, UInt64(Int.max))))) ?? Data()
                guard !data.isEmpty else { break }
                offset += UInt64(data.count)
                budget -= data.count
                consume(data)
            }
        } catch { return }
    }

    /// Finds the newest human input of a still-open turn within the last 16 MB.
    /// A completion marker found first means the latest turn is closed and the tail suffices.
    private func claudeTurnStart(handle: FileHandle, size: UInt64) -> UInt64? {
        let lowerBound = size > 16_777_216 ? size - 16_777_216 : 0
        var found: UInt64?
        try? scanLinesBackward(handle: handle, size: size, lowerBound: lowerBound) { line, lineOffset in
            switch parser.claudeTurnBoundary(in: line) {
            case .start?: found = lineOffset; return true
            case .end?: return true
            case nil: return false
            }
        }
        return found
    }

    /// Visits complete lines newest first. Lines over 64 KB and an unterminated last record are skipped.
    private func scanLinesBackward(handle: FileHandle, size: UInt64, lowerBound: UInt64,
                                   visit: (Data, UInt64) -> Bool) throws {
        var end = size
        var partial = Data()
        var dropping = true
        while end > lowerBound {
            let start = max(lowerBound, end > 65_536 ? end - 65_536 : 0)
            try handle.seek(toOffset: start)
            let chunk = try handle.read(upToCount: Int(end - start)) ?? Data()
            guard !chunk.isEmpty else { return }
            var cursor = chunk.endIndex
            while cursor > chunk.startIndex {
                let newline = chunk[..<cursor].lastIndex(of: 10)
                let lineStart = newline.map { chunk.index(after: $0) } ?? chunk.startIndex
                if !dropping {
                    if partial.count + chunk.distance(from: lineStart, to: cursor) <= 65_536 {
                        var assembled = Data(chunk[lineStart..<cursor])
                        assembled.append(partial)
                        partial = assembled
                    } else {
                        partial.removeAll(keepingCapacity: true)
                        dropping = true
                    }
                }
                guard let newline else { break }
                let lineOffset = start + UInt64(chunk.distance(from: chunk.startIndex, to: lineStart))
                if !dropping, !partial.isEmpty, visit(partial, lineOffset) { return }
                partial.removeAll(keepingCapacity: true)
                dropping = false
                cursor = newline
            }
            end = start
        }
        if end == 0, !dropping, !partial.isEmpty { _ = visit(partial, 0) }
    }

    private func restoreCodexMetadata(handle: FileHandle, size: UInt64) {
        let lowerBound = size > 16_777_216 ? size - 16_777_216 : 0
        var end = size
        var partial = Data()
        var dropping = true // A not-yet-terminated last record cannot supply metadata.
        var lifecycle: CodexMetadataCheckpoint?
        var opener: CodexMetadataCheckpoint?
        var contexts: [CodexMetadataCheckpoint] = []
        var latestUsage: CodexMetadataCheckpoint?
        func matchingContext() -> CodexMetadataCheckpoint? {
            guard let lifecycle else { return nil }
            return contexts.first { $0.turnID == nil || $0.turnID == lifecycle.turnID }
        }
        func metadataReady() -> Bool {
            guard lifecycle != nil, let opener else { return false }
            return opener.isInherited || matchingContext() != nil
        }
        func inspect(_ line: Data) {
            guard let checkpoint = parser.codexMetadataCheckpoint(in: line) else { return }
            if checkpoint.turnOutputTokens != nil {
                // Scanning backwards: the first usage record is the newest one.
                if latestUsage == nil, lifecycle == nil { latestUsage = checkpoint }
                return
            }
            if checkpoint.opensTurn != nil {
                if lifecycle == nil {
                    lifecycle = checkpoint
                    if checkpoint.opensTurn == true { opener = checkpoint }
                } else if opener == nil, checkpoint.opensTurn == true,
                          checkpoint.turnID == lifecycle?.turnID {
                    opener = checkpoint
                }
            } else if contexts.count < 16 { contexts.append(checkpoint) }
        }
        do {
            while end > lowerBound && !metadataReady() {
                let start = max(lowerBound, end > 65_536 ? end - 65_536 : 0)
                try handle.seek(toOffset: start)
                let chunk = try handle.read(upToCount: Int(end - start)) ?? Data()
                guard !chunk.isEmpty else { break }
                var cursor = chunk.endIndex
                while cursor > chunk.startIndex {
                    let newline = chunk[..<cursor].lastIndex(of: 10)
                    let lineStart = newline.map { chunk.index(after: $0) } ?? chunk.startIndex
                    if !dropping {
                        if partial.count + chunk.distance(from: lineStart, to: cursor) <= 65_536 {
                            var assembled = Data(chunk[lineStart..<cursor])
                            assembled.append(partial)
                            partial = assembled
                        } else {
                            partial.removeAll(keepingCapacity: true)
                            dropping = true
                        }
                    }
                    guard let newline else { break }
                    if !dropping { inspect(partial) }
                    partial.removeAll(keepingCapacity: true)
                    dropping = false
                    cursor = newline
                    if metadataReady() { break }
                }
                end = start
            }
            if end == 0 && !dropping && !partial.isEmpty { inspect(partial) }
            parser.restoreCodexMetadata(context: matchingContext(), lifecycle: lifecycle, opener: opener, usage: latestUsage)
        } catch { return }
    }

    private func consume(_ data: Data) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !droppingLine {
                if pending.count + data.distance(from: start, to: end) <= maximumLineBytes {
                    pending.append(contentsOf: data[start..<end])
                } else {
                    // An oversized tool result still names the call it completes near its start.
                    var head = pending.prefix(16_384)
                    head.append(contentsOf: data[start..<end].prefix(16_384 - head.count))
                    parser.consumeOversizedPrefix(Data(head))
                    pending.removeAll(keepingCapacity: false)
                    droppingLine = true
                }
            }
            guard let newline else { break }
            if !droppingLine { parser.consume(pending) }
            pending.removeAll(keepingCapacity: true)
            droppingLine = false
            start = data.index(after: newline)
        }
    }
}

struct TokenTurnCompletion {
    let output: Int
    let seconds: TimeInterval
    let finishedAt: Date
    let model: String?
    let quality: String
    var rate: Double { Double(output) / seconds }
}

fileprivate struct CodexMetadataCheckpoint {
    let turnID: String?
    let model: String?
    let cwd: String?
    let opensTurn: Bool?
    let timestamp: Date?
    let isInherited: Bool
    let actualStart: Date?
    let activityState: TokenActivityState
    var turnOutputTokens: Int? = nil
}

/// Only usage, timestamps, lifecycle IDs and model names survive parsing.
final class TokenLogParser {
    let source: TokenSource
    private(set) var sessionID: String?
    private(set) var parentSessionID: String?
    private(set) var agentID: String?
    private(set) var project: String?
    private(set) var isSubagent: Bool
    private(set) var model: String?
    private(set) var lastActivity: Date?
    /// Newest record timestamp of any kind. Liveness only; content state uses lastActivity.
    private(set) var lastLogAt: Date?
    private(set) var latestOutput: Int?
    private(set) var completion: TokenTurnCompletion?
    private(set) var lastOutputAt: Date?
    private(set) var lastOutputDelta: Int?
    private(set) var recentOutputs: [TokenOutputEvent] = []
    private var startedAt: Date?
    private var turnID: String?
    private var output = 0
    private var hasUsage = false
    private var accurate = true
    private var cumulativeOutput: Int?
    private var messages: [String: Int] = [:]
    private var previousMessages = Set<String>()
    private var closedTurnIDs = Set<String>()
    private var sessionCreatedAt: Date?
    private var ignoringInheritedTurn = false
    private var ignoredTurnID: String?
    private var inheritedTurnClosed = false
    private var pendingContext: (id: String?, model: String, cwd: String?)?
    private var metadataTurnOpen = false
    private var metadataTurnID: String?
    private var activityStartedAt: Date?
    private var observedState: TokenActivityState = .idle
    private var pendingTools = Set<String>()
    /// Codex writes token_usage_record right after each response, before the tool
    /// output that precedes the matching token_count. Once present it is authoritative.
    private var usageRecords = false
    private var seenResponses = Set<String>()
    private var turnUsage: (turnID: String, output: Int)?
    private let ownSessionID: String?
    private var identityLocked = false
    /// Claude: a final reply (end_turn without tool use) or an API error closes the turn unless
    /// later records continue it, e.g. a blocking Stop hook. Subagents write no stop markers.
    private var softClosed = false
    private var seenRecords = Set<String>()
    private var outputMessageID: String?
    private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDate = ISO8601DateFormatter()

    init(source: TokenSource, isSubagent: Bool = false, ownSessionID: String? = nil) {
        self.source = source
        self.isSubagent = isSubagent
        self.ownSessionID = ownSessionID
    }

    func consume(_ data: Data) {
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        consumeMetadata(record)
        let date = Self.date(record["timestamp"])
        switch source {
        case .codex: consumeCodex(record)
        case .claude: consumeClaude(record, previousLog: lastLogAt)
        }
        if let date { lastLogAt = max(lastLogAt ?? date, date) }
    }

    func consumeMetadata(_ data: Data) {
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        consumeMetadata(record)
    }

    private func consumeMetadata(_ record: [String: Any]) {
        if source == .claude, record["isSidechain"] as? Bool == true, !isSubagent { return }
        var cwd: String?
        if source == .codex, record["type"] as? String == "session_meta",
           let payload = record["payload"] as? [String: Any] {
            // Forked logs replay the parent's session_meta after their own; it must not
            // replace this thread's identity or creation time (which detects inherited turns).
            let id = payload["id"] as? String ?? payload["session_id"] as? String
            if let ownSessionID { guard id?.lowercased() == ownSessionID else { return } }
            else if identityLocked { return }
            identityLocked = true
            sessionID = id ?? sessionID
            sessionCreatedAt = Self.date(payload["timestamp"]) ?? sessionCreatedAt
            cwd = payload["cwd"] as? String
            if let sourceInfo = payload["source"] as? [String: Any], let subagent = sourceInfo["subagent"] {
                isSubagent = true
                agentID = payload["agent_path"] as? String ?? payload["agent_id"] as? String ?? sessionID
                let spawn = (subagent as? [String: Any])?["thread_spawn"] as? [String: Any]
                let root = (payload["session_id"] as? String).flatMap { $0 != id ? $0 : nil }
                parentSessionID = root ?? spawn?["parent_thread_id"] as? String ?? payload["parent_thread_id"] as? String
            }
        } else if source == .claude {
            sessionID = record["sessionId"] as? String ?? sessionID
            agentID = record["agentId"] as? String ?? agentID
            cwd = record["cwd"] as? String
            if isSubagent { parentSessionID = sessionID }
        }
        if let cwd, !cwd.isEmpty { project = URL(fileURLWithPath: cwd).lastPathComponent }
    }

    private var turnOpen: Bool { (startedAt != nil || metadataTurnOpen) && !softClosed }
    private var liveAt: Date? { [lastLogAt, lastActivity].compactMap { $0 }.max() }

    /// How long an open turn may stay silent and still count as running. Codex tools yield
    /// within 30 s; Claude tools (Bash, questions) can run for minutes; model waits reach ~8 min.
    private var liveHorizon: TimeInterval {
        if pendingTools.isEmpty { return 600 }
        return source == .claude ? 900 : 120
    }

    func isActive(at now: Date) -> Bool {
        guard turnOpen, let liveAt else { return false }
        let age = now.timeIntervalSince(liveAt)
        return age >= -5 && age <= liveHorizon
    }

    /// Worth keeping a cursor for even when newer files outrank it.
    func isRecent(at now: Date) -> Bool {
        turnOpen || liveAt.map { now.timeIntervalSince($0) <= 3_600 } == true
    }

    var currentTurnStartedAt: Date? {
        turnOpen ? activityStartedAt : nil
    }

    var currentTurnOutputTokens: Int? {
        guard turnOpen else { return nil }
        // Codex reports the whole turn's output directly, even when its start is outside the tail.
        if let turnUsage, turnUsage.turnID == (turnID ?? metadataTurnID) { return turnUsage.output }
        return startedAt != nil && accurate ? output : nil
    }

    private func recordOutput(_ tokens: Int, at date: Date?) {
        guard tokens > 0 else { return }
        if let date { lastActivity = max(lastActivity ?? date, date) }
        lastOutputAt = date
        lastOutputDelta = tokens
        guard let date else { return }
        recentOutputs.append(TokenOutputEvent(at: date, tokens: tokens))
        if recentOutputs.count > 512 { recentOutputs.removeFirst(recentOutputs.count - 512) }
    }

    func activityState(at now: Date) -> TokenActivityState {
        guard turnOpen else { return observedState }
        if isActive(at: now) { return observedState }
        guard let liveAt, now.timeIntervalSince(liveAt) <= 1_800 else { return .unfinished }
        return .stale
    }

    fileprivate func codexMetadataCheckpoint(in data: Data) -> CodexMetadataCheckpoint? {
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
        guard prefix.contains("\"turn_context\"") || prefix.contains("\"event_msg\"")
                || prefix.contains("\"token_usage_record\""),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else { return nil }
        let id = payload["turn_id"] as? String
        if record["type"] as? String == "token_usage_record" {
            guard let id, let turn = payload["turn_token_usage"] as? [String: Any],
                  let output = Self.integer(turn["output_tokens"]) else { return nil }
            return CodexMetadataCheckpoint(turnID: id, model: nil, cwd: nil, opensTurn: nil,
                timestamp: Self.date(record["timestamp"]), isInherited: false, actualStart: nil,
                activityState: .idle, turnOutputTokens: output)
        }
        if record["type"] as? String == "turn_context", let model = payload["model"] as? String {
            return CodexMetadataCheckpoint(turnID: id, model: model, cwd: payload["cwd"] as? String,
                opensTurn: nil, timestamp: Self.date(record["timestamp"]), isInherited: false,
                actualStart: nil, activityState: .idle)
        }
        guard record["type"] as? String == "event_msg",
              let event = payload["type"] as? String,
              ["task_started", "task_complete", "turn_aborted", "task_aborted"].contains(event) else { return nil }
        let start = Self.date(payload["started_at"]) ?? Self.date(record["timestamp"])
        let inherited = start.map { start in
            sessionCreatedAt.map { start < $0.addingTimeInterval(-1.5) } ?? false
        } ?? false
        return CodexMetadataCheckpoint(turnID: id, model: nil, cwd: nil,
            opensTurn: event == "task_started", timestamp: Self.date(record["timestamp"]) ?? start,
            isInherited: inherited, actualStart: event == "task_started" ? start : nil,
            activityState: event == "task_started" ? .working : (event == "task_complete" ? .complete : .interrupted))
    }

    fileprivate func restoreCodexMetadata(context: CodexMetadataCheckpoint?,
                                         lifecycle: CodexMetadataCheckpoint?, opener: CodexMetadataCheckpoint?,
                                         usage: CodexMetadataCheckpoint? = nil) {
        guard let lifecycle else { return }
        // A completion's write time does not establish who owned the turn. Its actual
        // matching start must be found within the bounded scan before restoring history.
        guard let opener, !opener.isInherited else {
            ignoringInheritedTurn = true
            ignoredTurnID = lifecycle.turnID
            inheritedTurnClosed = lifecycle.opensTurn == false
            pendingContext = nil
            model = nil
            cumulativeOutput = nil
            metadataTurnOpen = false
            metadataTurnID = nil
            activityStartedAt = nil
            observedState = .idle
            return
        }
        if let context {
            model = context.model ?? model
            if let cwd = context.cwd { project = URL(fileURLWithPath: cwd).lastPathComponent }
        }
        metadataTurnOpen = lifecycle.opensTurn == true
        metadataTurnID = metadataTurnOpen ? lifecycle.turnID : nil
        activityStartedAt = metadataTurnOpen ? opener.actualStart : nil
        observedState = lifecycle.activityState
        if let date = lifecycle.timestamp { lastActivity = max(lastActivity ?? date, date) }
        if let usage {
            usageRecords = true
            if metadataTurnOpen, let id = usage.turnID, id == metadataTurnID, let output = usage.turnOutputTokens {
                turnUsage = (id, output)
                if let date = usage.timestamp { lastActivity = max(lastActivity ?? date, date) }
            }
        }
    }

    private func begin(id: String?, date: Date?) {
        startedAt = date
        softClosed = false
        metadataTurnOpen = false
        metadataTurnID = nil
        activityStartedAt = date
        observedState = .working
        lastOutputAt = nil
        lastOutputDelta = nil
        pendingTools.removeAll(keepingCapacity: true)
        turnID = id
        turnUsage = nil
        output = 0
        hasUsage = false
        accurate = true
        previousMessages.formUnion(messages.keys)
        if previousMessages.count > 2_048 { previousMessages.removeAll(keepingCapacity: true) }
        messages.removeAll(keepingCapacity: true)
    }

    private func finish(at date: Date?, duration: TimeInterval?) {
        let seconds = duration ?? date.flatMap { finished in startedAt.map { finished.timeIntervalSince($0) } }
        let total = turnUsage.flatMap { $0.turnID == turnID ? $0.output : nil } ?? output
        if startedAt != nil, accurate, hasUsage, total > 0,
           let seconds, seconds.isFinite, seconds > 0, let date {
            completion = TokenTurnCompletion(output: total, seconds: seconds, finishedAt: date,
                model: model, quality: "완료된 턴 평균 · 도구·대기 포함")
            latestOutput = total
        }
        startedAt = nil
        turnID = nil
        turnUsage = nil
        softClosed = false
        metadataTurnOpen = false
        metadataTurnID = nil
        activityStartedAt = nil
        observedState = .complete
        pendingTools.removeAll(keepingCapacity: true)
    }

    private func consumeCodex(_ record: [String: Any]) {
        let type = record["type"] as? String
        let payload = record["payload"] as? [String: Any] ?? [:]
        if type == "session_meta" { return }
        if type == "token_usage_record" {
            consumeCodexUsageRecord(payload, date: Self.date(record["timestamp"]))
            return
        }
        if type == "turn_context" {
            if let contextModel = payload["model"] as? String {
                if !ignoringInheritedTurn {
                    model = contextModel
                    if let cwd = payload["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
                }
                else if inheritedTurnClosed {
                    pendingContext = (payload["turn_id"] as? String, contextModel, payload["cwd"] as? String)
                }
            }
            return
        }
        if type == "response_item", !ignoringInheritedTurn,
           startedAt != nil || metadataTurnOpen,
           let itemType = payload["type"] as? String {
            let phase: TokenActivityState?
            switch itemType {
            case "function_call", "custom_tool_call":
                if let id = payload["call_id"] as? String { pendingTools.insert(id) }
                phase = .tool
            case "function_call_output", "custom_tool_call_output":
                if let id = payload["call_id"] as? String { pendingTools.remove(id) }
                phase = pendingTools.isEmpty ? .working : .tool
            case "reasoning": phase = pendingTools.isEmpty ? .working : .tool
            case "agent_message": phase = pendingTools.isEmpty ? .output : .tool
            case "message": phase = payload["role"] as? String == "assistant"
                ? (pendingTools.isEmpty ? .output : .tool) : nil
            default: phase = nil
            }
            if let phase {
                observedState = phase
                if let date = Self.date(record["timestamp"]) { lastActivity = max(lastActivity ?? date, date) }
            }
            return
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
        let date = Self.date(record["timestamp"])
        switch event {
        case "task_started":
            let id = payload["turn_id"] as? String
            let start = Self.date(payload["started_at"]) ?? date
            // Forked logs can replay parent lifecycle events with the child's write time.
            // payload.started_at identifies turns older than this log's actual session.
            if let start, let sessionCreatedAt, start < sessionCreatedAt.addingTimeInterval(-1.5) {
                if startedAt == nil {
                    ignoringInheritedTurn = true
                    ignoredTurnID = id
                    inheritedTurnClosed = false
                    pendingContext = nil
                    model = nil
                    cumulativeOutput = nil
                }
                return
            }
            if let id, closedTurnIDs.contains(id) { return }
            if id != nil && id == turnID { return }
            ignoringInheritedTurn = false
            ignoredTurnID = nil
            inheritedTurnClosed = false
            if let pendingContext, pendingContext.id == nil || pendingContext.id == id {
                model = pendingContext.model
                if let cwd = pendingContext.cwd { project = URL(fileURLWithPath: cwd).lastPathComponent }
            }
            pendingContext = nil
            begin(id: id, date: start)
            metadataTurnOpen = true
            metadataTurnID = id
            lastActivity = date ?? lastActivity
        case "token_count":
            // The matching token_usage_record already counted this response.
            if ignoringInheritedTurn || usageRecords { return }
            guard let info = payload["info"] as? [String: Any] else { return }
            guard let total = info["total_token_usage"] as? [String: Any],
                  let count = Self.integer(total["output_tokens"]) else {
                if startedAt != nil { accurate = false }
                return
            }
            let last = (info["last_token_usage"] as? [String: Any]).flatMap { Self.integer($0["output_tokens"]) }
            let delta: Int?
            if let previous = cumulativeOutput {
                delta = count >= previous ? count - previous : last
            } else { delta = last }
            cumulativeOutput = count
            if let delta, delta >= 0 {
                if delta > 0 {
                    lastActivity = date ?? lastActivity
                    latestOutput = delta
                    recordOutput(delta, at: date)
                }
                if startedAt != nil {
                    output += delta
                    hasUsage = true
                }
            } else if startedAt != nil { accurate = false }
        case "task_complete":
            let id = payload["turn_id"] as? String
            if ignoringInheritedTurn, id == ignoredTurnID {
                inheritedTurnClosed = true
                return
            }
            if metadataTurnOpen && id == metadataTurnID {
                metadataTurnOpen = false
                metadataTurnID = nil
                activityStartedAt = nil
                observedState = .complete
                pendingTools.removeAll(keepingCapacity: true)
                lastActivity = date ?? lastActivity
            }
            guard turnID == id, startedAt != nil else { return }
            let milliseconds = Self.number(payload["duration_ms"])
            let duration = milliseconds.flatMap { $0 > 0 ? $0 / 1_000 : nil }
            let finished = Self.date(payload["completed_at"]) ?? date
            finish(at: finished, duration: duration)
            lastActivity = date ?? lastActivity
            if let id {
                closedTurnIDs.insert(id)
                if closedTurnIDs.count > 256 { closedTurnIDs = [id] }
            }
        case "turn_aborted", "task_aborted":
            if ignoringInheritedTurn { return }
            if let id = payload["turn_id"] as? String, let current = turnID ?? metadataTurnID, id != current { return }
            metadataTurnOpen = false
            metadataTurnID = nil
            startedAt = nil
            turnID = nil
            turnUsage = nil
            activityStartedAt = nil
            observedState = .interrupted
            pendingTools.removeAll(keepingCapacity: true)
            lastActivity = date ?? lastActivity
        default: break
        }
    }

    private func consumeCodexUsageRecord(_ payload: [String: Any], date: Date?) {
        if ignoringInheritedTurn { return }
        guard let usage = payload["usage"] as? [String: Any],
              let delta = Self.integer(usage["output_tokens"]) else { return }
        let id = payload["turn_id"] as? String
        let current = turnID ?? metadataTurnID
        // A record for a different turn than the open one is replayed history, not this turn's output.
        if let id, let current, id != current { return }
        if let response = payload["response_id"] as? String {
            guard !seenResponses.contains(response) else { return }
            if seenResponses.count >= 4_096 { seenResponses.removeAll(keepingCapacity: true) }
            seenResponses.insert(response)
        }
        usageRecords = true
        if let id, id == current, let turn = payload["turn_token_usage"] as? [String: Any],
           let total = Self.integer(turn["output_tokens"]) {
            turnUsage = (id, total)
        }
        if delta > 0 {
            latestOutput = delta
            recordOutput(delta, at: date)
        }
        if startedAt != nil {
            output += delta
            hasUsage = true
        }
    }

    private func consumeClaude(_ record: [String: Any], previousLog: Date?) {
        if record["isSidechain"] as? Bool == true && !isSubagent { return }
        let type = record["type"] as? String
        let date = Self.date(record["timestamp"])
        // Restored or branched sessions re-append earlier records with their original uuids
        // and timestamps; replaying them would rewind the turn.
        if let uuid = record["uuid"] as? String {
            guard !seenRecords.contains(uuid) else { return }
            if seenRecords.count >= 8_192 { seenRecords.removeAll(keepingCapacity: true) }
            seenRecords.insert(uuid)
        }
        if let date, let previousLog, date < previousLog.addingTimeInterval(-600) { return }
        sessionID = record["sessionId"] as? String ?? sessionID
        let message = record["message"] as? [String: Any] ?? [:]
        if type == "user" {
            guard record["isMeta"] as? Bool != true, record["isCompactSummary"] as? Bool != true else { return }
            switch Self.claudeInput(record, message: message) {
            case .human:
                begin(id: record["uuid"] as? String, date: date)
                if let date { lastActivity = max(lastActivity ?? date, date) }
            case .interrupted:
                closeTurn(.interrupted, at: date)
            case .toolResult:
                softClosed = false
                metadataTurnOpen = true
                let blocks = message["content"] as? [[String: Any]] ?? []
                for block in blocks where block["type"] as? String == "tool_result" {
                    if let id = block["tool_use_id"] as? String { pendingTools.remove(id) }
                }
                observedState = pendingTools.isEmpty ? .working : .tool
                if let date { lastActivity = max(lastActivity ?? date, date) }
                // Workflow agents end by returning their result through a tool.
                if record["toolEndsTurn"] as? Bool == true { closeTurn(.complete, at: date) }
            case .none: break
            }
        } else if type == "assistant" {
            guard let usage = message["usage"] as? [String: Any],
                  let count = Self.integer(usage["output_tokens"]),
                  let id = message["id"] as? String, !previousMessages.contains(id) else { return }
            let errored = record["isApiErrorMessage"] as? Bool == true || message["model"] as? String == "<synthetic>"
            if !errored { model = message["model"] as? String ?? model }
            let prior = messages[id] ?? 0
            messages[id] = max(prior, count)
            if let date { lastActivity = max(lastActivity ?? date, date) }
            softClosed = false
            let blocks = message["content"] as? [[String: Any]] ?? []
            let usesTool = blocks.contains(where: { $0["type"] as? String == "tool_use" })
            if usesTool {
                for block in blocks where block["type"] as? String == "tool_use" {
                    if let id = block["id"] as? String { pendingTools.insert(id) }
                }
                observedState = .tool
            } else if blocks.contains(where: { $0["type"] as? String == "text" }) {
                observedState = pendingTools.isEmpty ? .output : .tool
            } else if blocks.contains(where: { $0["type"] as? String == "thinking" }) {
                observedState = pendingTools.isEmpty ? .working : .tool
            }
            if count > prior {
                if startedAt != nil { output += count - prior; hasUsage = true }
                latestOutput = startedAt == nil ? count : output
                recordOutput(count - prior, at: date)
                outputMessageID = id
            } else if id == outputMessageID, let date, let last = lastOutputAt, date > last {
                // Main sessions write a message's blocks at its end with earlier block times;
                // the newest block time is the closest to when its tokens were recorded.
                lastOutputAt = date
                if let index = recentOutputs.indices.last { recentOutputs[index].at = max(recentOutputs[index].at, date) }
            }
            if errored {
                softClosed = true
                observedState = .interrupted
            } else if !usesTool, pendingTools.isEmpty,
                      ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "") {
                softClosed = true
                observedState = .complete
            }
        } else if type == "system" {
            // A marker older than the current prompt belongs to an earlier turn.
            if let date, let startedAt, date < startedAt { return }
            switch record["subtype"] as? String {
            case "turn_duration":
                if let milliseconds = Self.number(record["durationMs"]), milliseconds > 0, startedAt != nil {
                    finish(at: date, duration: milliseconds / 1_000)
                    lastActivity = date ?? lastActivity
                } else { closeTurn(.complete, at: date) }
            case "stop_hook_summary": closeTurn(.complete, at: nil)
            case "turn_aborted", "task_aborted", "interrupted": closeTurn(.interrupted, at: date)
            default: break
            }
        }
    }

    /// Ends the turn without a completion record: no measured duration is available.
    private func closeTurn(_ state: TokenActivityState, at date: Date?) {
        startedAt = nil
        turnID = nil
        turnUsage = nil
        softClosed = false
        metadataTurnOpen = false
        metadataTurnID = nil
        activityStartedAt = nil
        observedState = state
        pendingTools.removeAll(keepingCapacity: true)
        if let date { lastActivity = max(lastActivity ?? date, date) }
    }

    /// Oversized lines are dropped, but a tool result still names its call near the start.
    func consumeOversizedPrefix(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        func value(after key: String) -> String? {
            guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
            let rest = text[range.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        let id: String?
        switch source {
        case .codex:
            guard !ignoringInheritedTurn, text.contains("\"type\":\"response_item\""),
                  text.contains("\"type\":\"function_call_output\"") || text.contains("\"type\":\"custom_tool_call_output\"")
            else { return }
            id = value(after: "call_id")
        case .claude:
            guard text.contains("\"type\":\"user\""), text.contains("\"type\":\"tool_result\""),
                  isSubagent || !text.contains("\"isSidechain\":true") else { return }
            id = value(after: "tool_use_id")
        }
        guard let id, pendingTools.remove(id) != nil else { return }
        if turnOpen { observedState = pendingTools.isEmpty ? .working : .tool }
    }

    enum ClaudeTurnBoundary { case start, end }

    /// Classifies a line for locating the current turn. Starting earlier than the true start
    /// is harmless: the forward parse resets at every later human input.
    func claudeTurnBoundary(in data: Data) -> ClaudeTurnBoundary? {
        guard data.range(of: Data("\"type\":\"user\"".utf8)) != nil || data.range(of: Data("\"type\":\"system\"".utf8)) != nil,
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if record["isSidechain"] as? Bool == true && !isSubagent { return nil }
        switch record["type"] as? String {
        case "system":
            let ends = ["turn_duration", "stop_hook_summary", "turn_aborted", "task_aborted", "interrupted"]
            return ends.contains(record["subtype"] as? String ?? "") ? .end : nil
        case "user":
            guard record["isMeta"] as? Bool != true, record["isCompactSummary"] as? Bool != true else { return nil }
            if record["toolEndsTurn"] as? Bool == true { return .end }
            switch Self.claudeInput(record, message: record["message"] as? [String: Any] ?? [:]) {
            case .human: return .start
            case .interrupted: return .end
            case .toolResult, .none: return nil
            }
        default: return nil
        }
    }

    private enum ClaudeInput { case human, interrupted, toolResult, none }

    /// `origin` marks prompts that start a turn (human, task notifications, peer sessions).
    /// Older logs lack it; local slash-command echoes are not prompts.
    private static func claudeInput(_ record: [String: Any], message: [String: Any]) -> ClaudeInput {
        let blocks = message["content"] as? [[String: Any]]
        let text = message["content"] as? String
            ?? blocks?.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        if text?.hasPrefix("[Request interrupted") == true { return .interrupted }
        if blocks?.contains(where: { $0["type"] as? String == "tool_result" }) == true { return .toolResult }
        if let origin = record["origin"] as? [String: Any] { return origin["kind"] is String ? .human : .none }
        if let text, ["<command-name>", "<command-message>", "<local-command-"].contains(where: { text.hasPrefix($0) }) {
            return .none
        }
        if text != nil || blocks?.isEmpty == false { return .human }
        return .none
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < Double(Int.max), double.rounded(.towardZero) == double else { return nil }
        return Int(double)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String { return fractionalDate.date(from: string) ?? plainDate.date(from: string) }
        if let seconds = number(value), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}
