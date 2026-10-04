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

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         now: @escaping () -> Date = Date.init,
         initialTailBytes: Int = 1_048_576,
         discoveryInterval: TimeInterval = 5) {
        home = homeDirectory
        clock = now
        self.initialTailBytes = max(128, initialTailBytes)
        self.discoveryInterval = discoveryInterval
    }

    func sample() -> [TokenReading] {
        let now = clock()
        if lastDiscovery == nil || now.timeIntervalSince(lastDiscovery!) >= discoveryInterval {
            discover()
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
            reading.agentID = parser.agentID
            reading.project = parser.project
            reading.isSubagent = parser.isSubagent
            reading.model = parser.model ?? completion?.model
            reading.measurementModel = completion?.model
            reading.lastActivity = parser.lastActivity
            reading.measurementAt = completion?.finishedAt ?? parser.lastActivity
            reading.active = running
            reading.activityState = parser.activityState(at: now)
            reading.currentTurnStartedAt = parser.currentTurnStartedAt
            reading.currentTurnOutputTokens = parser.currentTurnOutputTokens
            reading.lastOutputAt = parser.lastOutputAt
            reading.lastOutputDelta = parser.lastOutputDelta
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

    private func discover() {
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
        var found: [URL] = []
        for project in children(root) {
            let entries = children(project)
            found.append(contentsOf: entries.filter { $0.pathExtension == "jsonl" })
            for session in entries where session.pathExtension.isEmpty {
                let subagents = session.appendingPathComponent("subagents")
                found.append(contentsOf: claudeSubagentFiles(in: subagents, remainingDepth: 2))
            }
        }
        return recent(found)
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
        parser = TokenLogParser(source: source,
            isSubagent: source == .claude && url.path.contains("/subagents/"))
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
            parser = TokenLogParser(source: parser.source,
                isSubagent: parser.source == .claude && url.path.contains("/subagents/"))
        }
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
            identity = currentIdentity
            initialized = true
        }
        guard size > offset else { return }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: min(1_048_576, Int(min(size - offset, UInt64(Int.max))))) ?? Data()
            offset += UInt64(data.count)
            consume(data)
        } catch { return }
    }

    private func restoreCodexMetadata(handle: FileHandle, size: UInt64) {
        let lowerBound = size > 16_777_216 ? size - 16_777_216 : 0
        var end = size
        var partial = Data()
        var dropping = true // A not-yet-terminated last record cannot supply metadata.
        var lifecycle: CodexMetadataCheckpoint?
        var opener: CodexMetadataCheckpoint?
        var contexts: [CodexMetadataCheckpoint] = []
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
            parser.restoreCodexMetadata(context: matchingContext(), lifecycle: lifecycle, opener: opener)
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
}

/// Only usage, timestamps, lifecycle IDs and model names survive parsing.
final class TokenLogParser {
    let source: TokenSource
    private(set) var sessionID: String?
    private(set) var agentID: String?
    private(set) var project: String?
    private(set) var isSubagent: Bool
    private(set) var model: String?
    private(set) var lastActivity: Date?
    private(set) var latestOutput: Int?
    private(set) var completion: TokenTurnCompletion?
    private(set) var lastOutputAt: Date?
    private(set) var lastOutputDelta: Int?
    private var startedAt: Date?
    private var turnID: String?
    private var output = 0
    private var hasUsage = false
    private var accurate = true
    private var cumulativeOutput: Int?
    private var messages: [String: Int] = [:]
    private var previousMessages = Set<String>()
    private var turnUUIDs = Set<String>()
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
    private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDate = ISO8601DateFormatter()

    init(source: TokenSource, isSubagent: Bool = false) {
        self.source = source
        self.isSubagent = isSubagent
    }

    func consume(_ data: Data) {
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        consumeMetadata(record)
        switch source {
        case .codex: consumeCodex(record)
        case .claude: consumeClaude(record)
        }
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
            sessionID = payload["id"] as? String ?? payload["session_id"] as? String ?? sessionID
            sessionCreatedAt = Self.date(payload["timestamp"]) ?? sessionCreatedAt
            cwd = payload["cwd"] as? String
            if let sourceInfo = payload["source"] as? [String: Any], sourceInfo["subagent"] != nil {
                isSubagent = true
                agentID = payload["agent_path"] as? String ?? payload["agent_id"] as? String ?? sessionID
            }
        } else if source == .claude {
            sessionID = record["sessionId"] as? String ?? sessionID
            agentID = record["agentId"] as? String ?? agentID
            cwd = record["cwd"] as? String
        }
        if let cwd, !cwd.isEmpty { project = URL(fileURLWithPath: cwd).lastPathComponent }
    }

    func isActive(at now: Date) -> Bool {
        guard startedAt != nil || metadataTurnOpen, let lastActivity else { return false }
        let age = now.timeIntervalSince(lastActivity)
        return age >= -5 && age <= 120
    }

    var currentTurnStartedAt: Date? {
        startedAt != nil || metadataTurnOpen ? activityStartedAt : nil
    }

    var currentTurnOutputTokens: Int? {
        startedAt != nil && accurate ? output : nil
    }

    func activityState(at now: Date) -> TokenActivityState {
        if startedAt != nil || metadataTurnOpen {
            return isActive(at: now) ? observedState : .stale
        }
        return observedState
    }

    fileprivate func codexMetadataCheckpoint(in data: Data) -> CodexMetadataCheckpoint? {
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
        guard prefix.contains("\"turn_context\"") || prefix.contains("\"event_msg\""),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else { return nil }
        let id = payload["turn_id"] as? String
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
                                         lifecycle: CodexMetadataCheckpoint?, opener: CodexMetadataCheckpoint?) {
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
    }

    private func begin(id: String?, date: Date?, uuid: String? = nil) {
        startedAt = date
        metadataTurnOpen = false
        metadataTurnID = nil
        activityStartedAt = date
        observedState = .working
        lastOutputAt = nil
        lastOutputDelta = nil
        pendingTools.removeAll(keepingCapacity: true)
        turnID = id
        output = 0
        hasUsage = false
        accurate = true
        previousMessages.formUnion(messages.keys)
        if previousMessages.count > 2_048 { previousMessages.removeAll(keepingCapacity: true) }
        messages.removeAll(keepingCapacity: true)
        turnUUIDs.removeAll(keepingCapacity: true)
        if let uuid { turnUUIDs.insert(uuid) }
    }

    private func finish(at date: Date?, duration: TimeInterval?) {
        let seconds = duration ?? date.flatMap { finished in startedAt.map { finished.timeIntervalSince($0) } }
        if startedAt != nil, accurate, hasUsage, output > 0,
           let seconds, seconds.isFinite, seconds > 0, let date {
            completion = TokenTurnCompletion(output: output, seconds: seconds, finishedAt: date,
                model: model, quality: "완료된 턴 평균 · 도구·대기 포함")
            latestOutput = output
        }
        startedAt = nil
        turnID = nil
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
            if ignoringInheritedTurn { return }
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
                    lastOutputAt = date
                    lastOutputDelta = delta
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
            activityStartedAt = nil
            observedState = .interrupted
            pendingTools.removeAll(keepingCapacity: true)
            lastActivity = date ?? lastActivity
        default: break
        }
    }

    private func consumeClaude(_ record: [String: Any]) {
        if record["isSidechain"] as? Bool == true && !isSubagent { return }
        sessionID = record["sessionId"] as? String ?? sessionID
        let type = record["type"] as? String
        let date = Self.date(record["timestamp"])
        let message = record["message"] as? [String: Any] ?? [:]
        let parent = record["parentUuid"] as? String
        let inputBoundary = type == "user" && record["isMeta"] as? Bool != true
            && record["isCompactSummary"] as? Bool != true
        if inputBoundary, !Self.isHumanUser(record, message: message) {
            metadataTurnOpen = true
            let blocks = message["content"] as? [[String: Any]] ?? []
            for block in blocks where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { pendingTools.remove(id) }
            }
            observedState = pendingTools.isEmpty ? .working : .tool
            if let date { lastActivity = max(lastActivity ?? date, date) }
        }
        if type == "user", Self.isHumanUser(record, message: message) {
            begin(id: record["uuid"] as? String, date: date, uuid: record["uuid"] as? String)
            lastActivity = date ?? lastActivity
        } else if type == "assistant" {
            guard let usage = message["usage"] as? [String: Any],
                  let count = Self.integer(usage["output_tokens"]),
                  let id = message["id"] as? String, !previousMessages.contains(id) else { return }
            model = message["model"] as? String ?? model
            let prior = messages[id] ?? 0
            messages[id] = max(prior, count)
            if let uuid = record["uuid"] as? String { turnUUIDs.insert(uuid) }
            if let date { lastActivity = max(lastActivity ?? date, date) }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if blocks.contains(where: { $0["type"] as? String == "tool_use" }) {
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
                lastOutputAt = date
                lastOutputDelta = count - prior
            }
        } else if type == "system", record["subtype"] as? String == "turn_duration" {
            guard let milliseconds = Self.number(record["durationMs"]), milliseconds > 0 else { return }
            if let parent = record["parentUuid"] as? String, !turnUUIDs.contains(parent) { return }
            finish(at: date, duration: milliseconds / 1_000)
            lastActivity = date ?? lastActivity
        } else if type == "system", record["subtype"] as? String == "stop_hook_summary" {
            if let parent, turnUUIDs.contains(parent) {
                startedAt = nil
                turnID = nil
                metadataTurnOpen = false
                metadataTurnID = nil
                activityStartedAt = nil
                observedState = .complete
                pendingTools.removeAll(keepingCapacity: true)
            }
        } else if type == "system", ["turn_aborted", "task_aborted", "interrupted"].contains(record["subtype"] as? String ?? "") {
            startedAt = nil
            turnID = nil
            metadataTurnOpen = false
            metadataTurnID = nil
            activityStartedAt = nil
            observedState = .interrupted
            pendingTools.removeAll(keepingCapacity: true)
            lastActivity = date ?? lastActivity
        }
    }

    private static func isHumanUser(_ record: [String: Any], message: [String: Any]) -> Bool {
        guard record["isMeta"] as? Bool != true,
              record["isCompactSummary"] as? Bool != true else { return false }
        if message["content"] is String { return true }
        guard let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty else { return false }
        return !blocks.contains { $0["type"] as? String == "tool_result" }
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
