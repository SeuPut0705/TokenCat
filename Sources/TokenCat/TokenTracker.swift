import Foundation
import CoreFoundation

/// Passive, bounded log reader. It never changes any client's configuration or saves transcripts.
/// Which clients and logs it reads comes from the provider registry (`TokenProvider.all`).
final class TokenTracker {
    private let home: URL
    private let environment: [String: String]
    private let providers: [TokenProvider]
    private let clock: () -> Date
    private let initialTailBytes: Int
    private let discoveryInterval: TimeInterval
    private var lastDiscovery: Date?
    private var files: [String: (source: TokenSource, reader: TokenLogReader)] = [:]
    /// Every log the last discovery listed, inside the caps or not: a write to one the caps left out opens its reader
    /// directly (it is now the newest), instead of rerunning discovery on each file event.
    private var known = Set<String>()
    private let manager = FileManager.default
    /// Each read client's root prefixes as given, under the real home and with the root's symlinks resolved: FSEvents and
    /// listings name real paths (/private/var for a temporary home, a symlinked ~/.codex by its target).
    private let logRoots: [(prefixes: [String], source: TokenSource, format: TokenLogFormat)]
    /// `TokenClientRoots` of read clients, with prefixes like `logRoots`: rows under them are another product's.
    private let clientRoots: [(prefixes: [String], name: String)]
    /// Readers kept past the discovery caps by `isRecent`, most recently active first.
    static let retentionLimit = 256
    static let recentOutputWindow: TimeInterval = 600

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         providers: [TokenProvider] = TokenProvider.all,
         now: @escaping () -> Date = Date.init,
         initialTailBytes: Int = 1_048_576,
         discoveryInterval: TimeInterval = 60) {
        home = homeDirectory
        self.environment = environment
        self.providers = providers
        func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let realHome = real(homeDirectory.path).map { URL(fileURLWithPath: $0, isDirectory: true) }
        func prefixes(_ roots: (URL, [String: String]) -> [URL]) -> [String] {
            let given = roots(homeDirectory, environment).map(\.path)
            let paths = given + (realHome.map { roots($0, environment).map(\.path) } ?? []) + given.compactMap(real)
            return Array(Set(paths.map { $0 + "/" }))
        }
        logRoots = providers.compactMap { provider in provider.format.map { (prefixes(provider.roots), provider.source, $0) } }
        let read = Set(providers.filter { $0.format != nil }.map(\.source))
        clientRoots = TokenClientRoots.all.filter { read.contains($0.source) }.map { (prefixes($0.roots), $0.clientName) }
        clock = now
        self.initialTailBytes = max(128, initialTailBytes)
        self.discoveryInterval = discoveryInterval
    }

    /// Candidate roots of every client with a parser; the watcher and the folder check keep the existing ones.
    var watchedDirectories: [URL] {
        providers.filter { $0.format != nil }.flatMap { $0.roots(home, environment) }
    }

    /// Clients whose data folder exists, read or not. Touches only the file system, never tracker state.
    func detectedSources() -> Set<TokenSource> {
        Set(providers.filter { !$0.existingRoots(home: home, environment: environment).isEmpty }.map(\.source))
    }

    /// Whether a changed path is a log of the client whose root holds it (a Claude subagent journal is not a Codex log).
    /// Uses only immutable state, so any thread may ask.
    func isLog(_ path: String) -> Bool { logRoot(of: path) != nil }

    /// Whether a file event should wake a sample: a log, or the `-wal` journal of a database log (OpenCode writes its
    /// changes there until a checkpoint). Other files under the watched roots wait for the 1 s timer. Any thread may ask.
    func wakesSampling(_ path: String) -> Bool {
        isLog(path) || (path.hasSuffix("-wal") && isLog(String(path.dropLast(4))))
    }

    private func logRoot(of path: String) -> (prefixes: [String], source: TokenSource, format: TokenLogFormat)? {
        logRoots.first { root in root.prefixes.contains(where: path.hasPrefix) && root.format.isLog(path) }
    }

    /// File-system events name changed paths. A log discovery has not seen triggers discovery on the next sample; one it
    /// listed but the caps left out is opened now, so the periodic rescan only catches what events missed.
    func noteChanged(paths: [String]) {
        for path in paths where files[path] == nil {
            guard let root = logRoot(of: path) else { continue }
            if known.contains(path) { files[path] = (root.source, root.format.open(URL(fileURLWithPath: path))) } else { lastDiscovery = nil }
        }
    }

    /// Runs discovery on the next sample: a client folder appeared, and logs written before it was watched sent no event.
    func rediscover() { lastDiscovery = nil }

    func sample() -> [TokenReading] {
        let now = clock()
        if lastDiscovery == nil || now.timeIntervalSince(lastDiscovery!) >= discoveryInterval {
            discover(now: now)
            lastDiscovery = now
        }
        // One pool per file: a cold start parses MBs of tails, and without it every temporary lives until the sample ends.
        for file in files.values { autoreleasepool { file.reader.read(tailLimit: initialTailBytes, now: now) } }
        let prefix = home.path + "/"
        return files.flatMap { path, file -> [TokenReading] in
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            let readings = file.reader.readings(id: "\(file.source.rawValue):\(relative)", now: now)
            guard let client = clientRoots.first(where: { $0.prefixes.contains(where: path.hasPrefix) })?.name else { return readings }
            return readings.map {
                var reading = $0
                reading.clientName = reading.clientName ?? client
                reading.rateLimit = nil
                return reading
            }
        }.sorted {
            if $0.active != $1.active { return $0.active }
            if $0.lastActivity != $1.lastActivity {
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
            return $0.id < $1.id
        }
    }

    private func discover(now: Date) {
        let discovery = TokenDiscovery(now: now)
        var retained = Set<String>()
        for provider in providers {
            guard let format = provider.format else { continue }
            let roots = provider.existingRoots(home: home, environment: environment)
            guard !roots.isEmpty else { continue }
            for url in format.files(roots, discovery) {
                retained.insert(url.path)
                if files[url.path] == nil { files[url.path] = (provider.source, format.open(url)) }
            }
        }
        known = discovery.known
        // A quiet session in a turn, or logged within the hour, is not evicted by a burst of newer subagent logs; re-adding
        // it later would restart from a bounded tail. Only these count against their own limit, open turns and the most
        // recently active first, so listing more clients never crowds them out.
        let kept = files.compactMap { path, file -> (path: String, active: Bool, last: Date)? in
            guard !retained.contains(path), file.reader.isRecent(at: now), manager.fileExists(atPath: path) else { return nil }
            let readings = file.reader.readings(id: path, now: now)
            return (path, readings.contains(where: \.active), readings.compactMap(\.lastActivity).max() ?? .distantPast)
        }.sorted {
            if $0.active != $1.active { return $0.active }
            return $0.last != $1.last ? $0.last > $1.last : $0.path < $1.path
        }.prefix(Self.retentionLimit)
        retained.formUnion(kept.map(\.path))
        files = files.filter { retained.contains($0.key) }
    }
}

extension TokenLogFormat {
    static let codex = TokenLogFormat(files: { roots, discovery in
        // A resumed conversation stays in its original UTC date directory. Select by file
        // modification time across date directories, without reading transcript bodies here.
        var found: [URL] = []
        func descending(_ urls: [URL]) -> [URL] { urls.sorted { $0.lastPathComponent > $1.lastPathComponent } }
        for root in roots {
            for year in descending(discovery.children(root).filter({ Int($0.lastPathComponent) != nil })) {
                for month in descending(discovery.children(year)) {
                    for day in descending(discovery.children(month)) {
                        found.append(contentsOf: discovery.children(day).filter { $0.pathExtension == "jsonl" })
                    }
                }
            }
        }
        return discovery.recent(found)
    }, isLog: { $0.hasSuffix(".jsonl") }, open: { TokenFileCursor(url: $0, source: .codex) })

    static let claude = TokenLogFormat(files: { roots, discovery in
        func subagentFiles(in directory: URL, remainingDepth: Int) -> [URL] {
            let entries = discovery.children(directory)
            var found = entries.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            if remainingDepth > 0 {
                for child in entries where child.pathExtension.isEmpty {
                    found.append(contentsOf: subagentFiles(in: child, remainingDepth: remainingDepth - 1))
                }
            }
            return found
        }
        var main: [URL] = []
        var subagents: [URL] = []
        for entry in roots.flatMap(discovery.children) {
            // Qoder's SharedClientCache keeps transcripts directly in its root, without project folders.
            if entry.pathExtension == "jsonl" { main.append(entry); continue }
            let entries = discovery.children(entry)
            main.append(contentsOf: entries.filter { $0.pathExtension == "jsonl" })
            for session in entries where session.pathExtension.isEmpty {
                subagents.append(contentsOf: subagentFiles(in: session.appendingPathComponent("subagents"), remainingDepth: 2))
            }
        }
        // `<session>.orphaned-<time>-<suffix>.jsonl` is a transcript Claude Code set aside; it is no session.
        let current = main.filter { !$0.lastPathComponent.contains(".orphaned-") }
        // Workflow agents create many files; they get their own cap so main sessions stay visible.
        return discovery.recent(current) + discovery.recent(subagents, keepingSince: discovery.now.addingTimeInterval(-3_600))
    }, isLog: { path in
        // Workflow journals and other side files under subagents/ are never tracked, nor set-aside transcripts.
        let name = (path as NSString).lastPathComponent
        return path.hasSuffix(".jsonl") && !name.contains(".orphaned-") && (!path.contains("/subagents/") || name.hasPrefix("agent-"))
    }, open: { TokenFileCursor(url: $0, source: .claude) })
}

/// Codex and Claude Code logs: a bounded JSONL tail fed line by line to `TokenLogParser`.
private final class TokenFileCursor: TokenLogReader {
    let url: URL
    private(set) var parser: TokenLogParser
    private var offset: UInt64 = 0
    private var identity: String?
    private var initialized = false
    private var pending = Data()
    private var droppingLine = false
    private let maximumLineBytes = 1_048_576
    /// Claude subagent type from `<log>.meta.json`; only `agentType` is kept.
    private(set) var sidecarRole: String?
    /// Codex: the thread-name index of this rollout's Codex home.
    private let threadNames: CodexThreadNames?

    init(url: URL, source: TokenSource) {
        self.url = url
        parser = Self.parser(for: url, source: source)
        threadNames = source == .codex ? CodexThreadNames.index(forRollout: url) : nil
    }

    func isRecent(at now: Date) -> Bool { parser.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard parser.lastActivity != nil else { return [] }
        let completion = parser.completion
        var reading = TokenReading(source: parser.source, id: id)
        reading.sessionID = parser.sessionID
        reading.parentSessionID = parser.parentSessionID
        reading.agentID = parser.agentID
        reading.project = parser.project
        reading.title = threadNames.map { $0.name(for: parser.sessionID) } ?? parser.title
        reading.projectPath = parser.projectPath
        reading.isSubagent = parser.isSubagent
        reading.agentRole = sidecarRole ?? parser.agentRole
        reading.effort = parser.effort
        reading.lastTurnDurationSeconds = parser.lastTurnDuration
        if let tool = parser.runningTool {
            reading.toolName = tool.name
            reading.toolCategory = tool.name.map(TokenLogParser.category) ?? .other
        }
        reading.retry = parser.retry
        reading.rateLimit = parser.rateLimit
        reading.context = parser.context
        reading.model = parser.model ?? completion?.model
        reading.lastActivity = parser.lastActivity
        reading.lastLogAt = parser.lastLogAt
        reading.measurementAt = completion?.finishedAt ?? parser.lastActivity
        reading.active = parser.isActive(at: now)
        reading.activityState = parser.activityState(at: now)
        reading.currentTurnStartedAt = parser.currentTurnStartedAt
        reading.currentTurnOutputTokens = parser.currentTurnOutputTokens
        reading.lastOutputAt = parser.lastOutputAt
        reading.lastOutputDelta = parser.lastOutputDelta
        reading.requestIDs = parser.requestIDs
        reading.recentOutputs = parser.recentOutputs.filter {
            let age = now.timeIntervalSince($0.at)
            return age >= -5 && age <= TokenTracker.recentOutputWindow
        }
        reading.sampledAt = now
        // Output of the last fully observed completed turn; its duration is a separate field.
        reading.lastOutputTokens = completion?.output
        return [reading]
    }

    /// The sidecar may be written after the log, so it is retried while the log grows.
    /// Its other keys (task description, worktree path) are never kept.
    private func readSidecar() {
        guard sidecarRole == nil, parser.source == .claude, parser.isSubagent else { return }
        let sidecar = url.deletingPathExtension().appendingPathExtension("meta.json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: sidecar.path))?[.size] as? NSNumber,
              size.intValue <= 16_384, let data = try? Data(contentsOf: sidecar),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        sidecarRole = TokenLogParser.label(object["agentType"])
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

    func read(tailLimit: Int, now: Date) {
        // Every sample, so liveness and the replay filter recover once records are stamped by a sane clock again.
        parser.clampClock(to: now.addingTimeInterval(5))
        threadNames?.refresh()
        // stat(2), not attributesOfItem: this runs for every tracked log on every tick, and the latter also reads xattrs.
        var info = stat()
        guard stat(url.path, &info) == 0 else { return }
        let size = UInt64(info.st_size)
        let currentIdentity = "\(info.st_dev)-\(info.st_ino)"
        if initialized && (identity != currentIdentity || size < offset) {
            offset = 0
            initialized = false
            pending.removeAll(keepingCapacity: false)
            droppingLine = false
            parser = Self.parser(for: url, source: parser.source)
        }
        // Unchanged logs are polled every tick; avoid reopening them.
        if initialized && size == offset { return }
        readSidecar()
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
                // Per chunk, so a long open turn read at once does not pile up its parsed objects.
                autoreleasepool { consume(data) }
            }
        } catch { return }
    }

    /// Finds the newest human input of a still-open turn within the last 16 MB.
    /// A completion marker found first means the latest turn is closed and the tail suffices.
    private func claudeTurnStart(handle: FileHandle, size: UInt64) -> UInt64? {
        let lowerBound = size > 16_777_216 ? size - 16_777_216 : 0
        var found: UInt64?
        try? scanLinesBackward(handle: handle, size: size, lowerBound: lowerBound) { line, lineOffset in
            switch autoreleasepool(invoking: { parser.claudeTurnBoundary(in: line) }) {
            case .start?: found = lineOffset; return true
            case .end?: return true
            case nil: return false
            }
        }
        return found
    }

    /// Visits complete lines newest first. Lines over `maximumLineBytes` (the forward limit; a prompt with a pasted image
    /// runs past 64 KB) and an unterminated last record are skipped.
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
                    if partial.count + chunk.distance(from: lineStart, to: cursor) <= maximumLineBytes {
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
            // A not-yet-terminated last record cannot supply metadata; the scanner skips it.
            try scanLinesBackward(handle: handle, size: size, lowerBound: lowerBound) { line, _ in
                inspect(line)
                return metadataReady()
            }
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

/// A fully observed completed turn. Output and the client-reported duration are never divided.
struct TokenTurnCompletion {
    let output: Int
    let durationSeconds: TimeInterval?
    let finishedAt: Date
    let model: String?
}

fileprivate struct CodexMetadataCheckpoint {
    let turnID: String?
    let model: String?
    let cwd: String?
    var effort: String? = nil
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
    private(set) var projectPath: String?
    private(set) var isSubagent: Bool
    private(set) var model: String?
    private(set) var effort: String?
    private(set) var agentRole: String?
    /// Claude Code: the newest `/rename` (`custom-title`), generated title (`ai-title`) and older builds' `summary`, ranked
    /// in that order as Claude Code's own session list does. The client re-appends them as the log grows, so a tail sees them.
    private var customTitle: String?
    private var generatedTitle: String?
    private var summaryTitle: String?
    var title: String? { customTitle ?? generatedTitle ?? summaryTitle }
    /// Client-reported duration of the last completed turn (Codex duration_ms, Claude durationMs).
    private(set) var lastTurnDuration: TimeInterval?
    private(set) var retry: TokenRetryState?
    private(set) var rateLimit: TokenRateLimit?
    private var contextUsage: TokenContextUsage?
    private var compactedAt: Date?
    /// Codex: an own (non-inherited) turn has been observed, so usage snapshots are this thread's.
    private var ownTurnSeen = false
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
    private var pendingContext: (id: String?, model: String, cwd: String?, effort: String?)?
    private var metadataTurnOpen = false
    private var metadataTurnID: String?
    private var activityStartedAt: Date?
    private var observedState: TokenActivityState = .idle
    /// Outstanding tool calls in call order, id → name. Inputs are never read.
    private var pendingTools: [(id: String, name: String?)] = []
    /// Tools that wait for the person rather than run: Claude's question and plan approval, and
    /// Codex's blocking request_user_input (plan mode). request_user_input_async is non-blocking.
    private static let inputTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "request_user_input"]
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
    /// Claude: request IDs of logged responses, so telemetry for an unlogged side request is not taken as this log's.
    private(set) var requestIDs = Set<String>()
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
        case .codex: consumeCodex(record, date: date)
        case .claude: consumeClaude(record, date: date, previousLog: lastLogAt)
        // Only Codex and Claude Code logs reach this parser (`TokenLogFormat.codex`/`.claude`).
        default: return
        }
        if let date { lastLogAt = max(lastLogAt ?? date, date) }
    }

    /// A record stamped ahead of the clock (or a clock set back) must not keep the newest times in the future: the session
    /// would stop counting as live and Claude's 10-minute replay filter would drop every new record.
    func clampClock(to ceiling: Date) {
        lastLogAt = lastLogAt.map { min($0, ceiling) }
        lastActivity = lastActivity.map { min($0, ceiling) }
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
                // Role, then nickname; automatic review threads carry only `subagent.other`.
                agentRole = [spawn?["agent_role"], payload["agent_role"], payload["agent_nickname"],
                             spawn?["agent_nickname"], (subagent as? [String: Any])?["other"]]
                    .lazy.compactMap { Self.label($0) }.first
            }
        } else if source == .claude {
            sessionID = record["sessionId"] as? String ?? sessionID
            agentID = record["agentId"] as? String ?? agentID
            cwd = record["cwd"] as? String
            if isSubagent { parentSessionID = sessionID }
            switch record["type"] as? String {
            case "custom-title": customTitle = SessionTitle.clean(record["customTitle"]) ?? customTitle
            case "ai-title": generatedTitle = SessionTitle.clean(record["aiTitle"]) ?? generatedTitle
            case "summary": summaryTitle = SessionTitle.clean(record["summary"]) ?? summaryTitle
            default: break
            }
        }
        setProject(cwd)
    }

    private func setProject(_ cwd: String?) {
        guard let cwd, !cwd.isEmpty else { return }
        project = URL(fileURLWithPath: cwd).lastPathComponent
        projectPath = cwd
    }

    /// A short client-defined name (role, nickname, effort); anything else is dropped.
    static func label(_ value: Any?) -> String? {
        guard let text = value as? String, (1...48).contains(text.count),
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " _.:-".unicodeScalars.contains($0) })
        else { return nil }
        return text
    }

    /// Category from the tool name only. Names verified in local logs: Claude Bash/Read/Write/
    /// Edit/WebFetch/WebSearch/Agent/Workflow/AskUserQuestion/mcp__*; Codex exec/js/spawn_agent/
    /// wait_agent/send_message/followup_task/list_agents/request_user_input_async.
    static func category(_ name: String) -> ToolCategory {
        if name.hasPrefix("mcp__") { return .mcp }
        switch name {
        case "Bash", "BashOutput", "exec", "exec_command", "shell", "local_shell", "js", "unified_exec": return .command
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Glob", "Grep", "apply_patch": return .file
        case "WebFetch", "WebSearch", "web_search", "web_fetch": return .web
        case "Task", "Agent", "Workflow", "SendMessage", "ListAgents", "spawn_agent", "wait_agent",
             "send_message", "followup_task", "list_agents", "close_agent": return .agent
        case "ListMcpResourcesTool", "ReadMcpResourceTool": return .mcp
        case "AskUserQuestion", "ExitPlanMode", "request_user_input", "request_user_input_async": return .question
        default: return .other
        }
    }

    /// The outstanding tool that holds an open turn: one waiting for the person, else the newest.
    var runningTool: (id: String, name: String?)? {
        guard turnOpen else { return nil }
        return pendingTools.last { Self.inputTools.contains($0.name ?? "") } ?? pendingTools.last
    }

    private var waitsForInput: Bool {
        turnOpen && pendingTools.contains { Self.inputTools.contains($0.name ?? "") }
    }

    var context: TokenContextUsage? {
        guard var usage = contextUsage else { return nil }
        usage.compactedAt = compactedAt
        return usage
    }

    private func addPendingTool(_ id: String, name: Any?) {
        pendingTools.removeAll { $0.id == id }
        pendingTools.append((id, name as? String))
        if pendingTools.count > 256 { pendingTools.removeFirst(pendingTools.count - 256) }
    }

    @discardableResult
    private func removePendingTool(_ id: String) -> Bool {
        guard let index = pendingTools.firstIndex(where: { $0.id == id }) else { return false }
        pendingTools.remove(at: index)
        return true
    }

    private var turnOpen: Bool { (startedAt != nil || metadataTurnOpen) && !softClosed }
    private var liveAt: Date? { [lastLogAt, lastActivity].compactMap { $0 }.max() }

    /// How long an open turn may stay silent and still count as running. Codex tools yield
    /// within 30 s; Claude tools (Bash, questions) can run for minutes; model waits reach ~8 min.
    /// A question or plan approval waits for the person, so it never goes stale; a client
    /// that was killed with the question open is capped at 24 hours.
    private var liveHorizon: TimeInterval {
        if waitsForInput { return 86_400 }
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
        if waitsForInput { return isActive(at: now) ? .input : .unfinished }
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
                effort: Self.codexEffort(payload), opensTurn: nil, timestamp: Self.date(record["timestamp"]),
                isInherited: false, actualStart: nil, activityState: .idle)
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
            effort = nil
            cumulativeOutput = nil
            metadataTurnOpen = false
            metadataTurnID = nil
            activityStartedAt = nil
            observedState = .idle
            return
        }
        if let context {
            model = context.model ?? model
            effort = context.effort ?? effort
            setProject(context.cwd)
        }
        ownTurnSeen = true
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
        retry = nil
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

    /// The open turn's whole output when it is known: Codex's recorded turn total, or every
    /// response of a turn observed from its start.
    private var observedTurnOutput: Int? {
        let id = turnID ?? metadataTurnID
        if let turnUsage, turnUsage.turnID == id { return turnUsage.output }
        return startedAt != nil && accurate && hasUsage ? output : nil
    }

    /// Records the last completed turn. An unknown output clears it rather than leaving an
    /// earlier turn's value under the "last completed turn" label.
    private func recordCompletion(at date: Date?, duration: TimeInterval?) {
        lastTurnDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let total = observedTurnOutput, total > 0, let finished = date ?? lastLogAt {
            completion = TokenTurnCompletion(output: total, durationSeconds: lastTurnDuration,
                                             finishedAt: finished, model: model)
            latestOutput = total
        } else { completion = nil }
    }

    /// `date` is the record's parsed `timestamp`.
    private func consumeCodex(_ record: [String: Any], date: Date?) {
        let type = record["type"] as? String
        let payload = record["payload"] as? [String: Any] ?? [:]
        if type == "session_meta" { return }
        if type == "token_usage_record" {
            consumeCodexUsageRecord(payload, date: date)
            return
        }
        if type == "turn_context" {
            if let contextModel = payload["model"] as? String {
                if !ignoringInheritedTurn {
                    model = contextModel
                    effort = Self.codexEffort(payload) ?? effort
                    setProject(payload["cwd"] as? String)
                }
                else if inheritedTurnClosed {
                    pendingContext = (payload["turn_id"] as? String, contextModel, payload["cwd"] as? String,
                                      Self.codexEffort(payload))
                }
            }
            return
        }
        // A compaction finished at this time. Forked logs replay the parent's before any own turn.
        if type == "compacted" {
            if ownUsageSnapshot, let date { compactedAt = max(compactedAt ?? date, date) }
            return
        }
        if type == "response_item", !ignoringInheritedTurn,
           startedAt != nil || metadataTurnOpen,
           let itemType = payload["type"] as? String {
            let phase: TokenActivityState?
            switch itemType {
            case "function_call", "custom_tool_call":
                if let id = payload["call_id"] as? String { addPendingTool(id, name: payload["name"]) }
                phase = .tool
            case "function_call_output", "custom_tool_call_output":
                if let id = payload["call_id"] as? String { removePendingTool(id) }
                phase = pendingTools.isEmpty ? .working : .tool
            case "reasoning": phase = pendingTools.isEmpty ? .working : .tool
            case "agent_message": phase = pendingTools.isEmpty ? .output : .tool
            case "message": phase = payload["role"] as? String == "assistant"
                ? (pendingTools.isEmpty ? .output : .tool) : nil
            default: phase = nil
            }
            if let phase {
                observedState = phase
                if let date { lastActivity = max(lastActivity ?? date, date) }
            }
            return
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
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
                    effort = nil
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
                effort = pendingContext.effort ?? effort
                setProject(pendingContext.cwd)
            }
            pendingContext = nil
            begin(id: id, date: start)
            ownTurnSeen = true
            metadataTurnOpen = true
            metadataTurnID = id
            lastActivity = date ?? lastActivity
        case "token_count":
            if ownUsageSnapshot, let date { consumeCodexSnapshot(payload, date: date) }
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
            // Only the open turn's own completion reports this thread's duration.
            guard (metadataTurnOpen && id == metadataTurnID) || (startedAt != nil && turnID == id) else { return }
            let duration = Self.number(payload["duration_ms"], max: Self.maxDurationMs).map { $0 / 1_000 }
            closeTurn(.complete, at: date, duration: duration, finishedAt: Self.date(payload["completed_at"]))
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

    /// Codex usage snapshots belong to this thread only after its own turn: forked logs
    /// replay the parent's records (with the child's write time) before the first own turn.
    private var ownUsageSnapshot: Bool { source == .codex && ownTurnSeen && !ignoringInheritedTurn }

    /// Account usage limit and context fill as the client wrote them; newest record wins.
    private func consumeCodexSnapshot(_ payload: [String: Any], date: Date) {
        // Accounts report one or two windows (e.g. 5-hour primary, weekly secondary); the most
        // constrained one is kept, labelled by its own window length.
        if let limits = payload["rate_limits"] as? [String: Any],
           (limits["limit_id"] as? String).map({ $0 == "codex" }) ?? true,
           rateLimit.map({ date >= $0.recordedAt }) ?? true,
           let window = ["primary", "secondary"].compactMap({ key -> TokenRateLimit? in
               guard let limit = limits[key] as? [String: Any], let used = Self.number(limit["used_percent"]),
                     used >= 0, used <= 1_000 else { return nil }
               return TokenRateLimit(usedPercent: used, windowMinutes: Self.integer(limit["window_minutes"]),
                                     resetsAt: Self.date(limit["resets_at"]), recordedAt: date)
           }).max(by: { ($0.usedPercent, $0.windowMinutes ?? 0) < ($1.usedPercent, $1.windowMinutes ?? 0) }) {
            rateLimit = window
        }
        // input_tokens already includes cached input; the window comes from the same record.
        if let info = payload["info"] as? [String: Any],
           let last = info["last_token_usage"] as? [String: Any], let input = Self.integer(last["input_tokens"]),
           contextUsage.map({ date >= $0.recordedAt }) ?? true {
            contextUsage = TokenContextUsage(usedTokens: input,
                windowTokens: Self.integer(info["model_context_window"]).flatMap { $0 > 0 ? $0 : nil },
                recordedAt: date, compactedAt: nil)
        }
    }

    private static func codexEffort(_ payload: [String: Any]) -> String? {
        let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
        return label(payload["effort"]) ?? label(settings?["reasoning_effort"])
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

    private func consumeClaude(_ record: [String: Any], date: Date?, previousLog: Date?) {
        if record["isSidechain"] as? Bool == true && !isSubagent { return }
        let type = record["type"] as? String
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
            // A peer-session message is marked isMeta but carries `origin`, and starts a turn like a prompt.
            guard record["isMeta"] as? Bool != true || record["origin"] is [String: Any],
                  record["isCompactSummary"] as? Bool != true else { return }
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
                    if let id = block["tool_use_id"] as? String { removePendingTool(id) }
                }
                observedState = pendingTools.isEmpty ? .working : .tool
                if let date { lastActivity = max(lastActivity ?? date, date) }
                // Workflow agents end by returning their result through a tool.
                if record["toolEndsTurn"] as? Bool == true { closeTurn(.complete, at: date) }
            case .none: break
            }
        } else if type == "assistant" {
            if let request = record["requestId"] as? String {
                if requestIDs.count >= 256 { requestIDs.removeAll(keepingCapacity: true) }
                requestIDs.insert(request)
            }
            guard let usage = message["usage"] as? [String: Any],
                  let count = Self.integer(usage["output_tokens"]),
                  let id = message["id"] as? String, !previousMessages.contains(id) else { return }
            let errored = record["isApiErrorMessage"] as? Bool == true || message["model"] as? String == "<synthetic>"
            // A response (or the final failure) ends any API retry in progress.
            retry = nil
            if !errored {
                model = message["model"] as? String ?? model
                // Context occupied by this request: all input-side counts. Claude logs no window size.
                if let date, let input = Self.integer(usage["input_tokens"]), contextUsage.map({ date >= $0.recordedAt }) ?? true {
                    let cached = ["cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { Self.integer(usage[$0]) }
                    contextUsage = TokenContextUsage(usedTokens: cached.reduce(input, +), windowTokens: nil,
                                                     recordedAt: date, compactedAt: nil)
                }
            }
            let prior = messages[id] ?? 0
            messages[id] = max(prior, count)
            if let date { lastActivity = max(lastActivity ?? date, date) }
            softClosed = false
            let blocks = message["content"] as? [[String: Any]] ?? []
            let usesTool = blocks.contains(where: { $0["type"] as? String == "tool_use" })
            if usesTool {
                for block in blocks where block["type"] as? String == "tool_use" {
                    if let id = block["id"] as? String { addPendingTool(id, name: block["name"]) }
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
                // Subagents write no stop marker; a later continuation records again.
                if startedAt != nil { recordCompletion(at: date, duration: nil) }
            }
        } else if type == "system" {
            let subtype = record["subtype"] as? String
            // Compaction end time; the boundary itself does not change the turn.
            if subtype == "compact_boundary", let date { compactedAt = max(compactedAt ?? date, date) }
            // A marker older than the current prompt belongs to an earlier turn.
            if let date, let startedAt, date < startedAt { return }
            switch subtype {
            case "turn_duration":
                closeTurn(.complete, at: date, duration: Self.number(record["durationMs"], max: Self.maxDurationMs).map { $0 / 1_000 })
            case "api_error":
                // Counts, delay and the network flag only; error messages are never read.
                guard turnOpen, let date, let attempt = Self.integer(record["retryAttempt"]) else { break }
                let delay = Self.number(record["retryInMs"], max: 86_400_000)
                retry = TokenRetryState(attempt: attempt, maxAttempts: Self.integer(record["maxRetries"]),
                                        retryAt: delay.map { date.addingTimeInterval($0 / 1_000) },
                                        networkDown: (record["error"] as? [String: Any])?["isNetworkDown"] as? Bool == true,
                                        at: date)
            case "stop_hook_summary": closeTurn(.complete, at: nil)
            case "turn_aborted", "task_aborted", "interrupted": closeTurn(.interrupted, at: date)
            default: break
            }
        }
    }

    /// Ends the turn. `duration` is only ever the client's own report for this turn.
    private func closeTurn(_ state: TokenActivityState, at date: Date?, duration: TimeInterval? = nil,
                           finishedAt: Date? = nil) {
        // A repeated stop marker after the turn already closed has no turn to complete.
        if state == .complete, startedAt != nil || metadataTurnOpen {
            recordCompletion(at: finishedAt ?? date, duration: duration)
        }
        retry = nil
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
        default: return
        }
        guard let id, removePendingTool(id) else { return }
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
            guard record["isMeta"] as? Bool != true || record["origin"] is [String: Any],
                  record["isCompactSummary"] as? Bool != true else { return nil }
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

    /// A week in milliseconds: longer client durations are treated as corrupt rather than shown.
    private static let maxDurationMs: Double = 604_800_000
    private static func number(_ value: Any?, max limit: Double) -> Double? {
        number(value).flatMap { $0 <= limit ? $0 : nil }
    }

    static func date(_ value: Any?) -> Date? {
        if let string = value as? String { return utcDate(string) ?? fractionalDate.date(from: string) ?? plainDate.date(from: string) }
        if let seconds = number(value), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    /// `yyyy-MM-ddTHH:mm:ss[.f{1,3}]Z` from 1970 with in-range fields, the shape both clients write, computed directly
    /// (ISO8601DateFormatter costs ~45 µs a call) to the same Date bit for bit; anything else goes to the formatters.
    private static func utcDate(_ string: String) -> Date? {
        let c = Array(string.utf8)
        guard [20, 22, 23, 24].contains(c.count), c[4] == 45, c[7] == 45, c[10] == 84, c[13] == 58, c[16] == 58,
              c[c.count - 1] == 90, c.count == 20 || c[19] == 46 else { return nil }
        func digits(_ from: Int, _ to: Int) -> Int? {
            var value = 0
            for i in from..<to { guard (48...57).contains(c[i]) else { return nil }; value = value * 10 + Int(c[i] - 48) }
            return value
        }
        guard let y = digits(0, 4), let m = digits(5, 7), let d = digits(8, 10),
              let h = digits(11, 13), let mi = digits(14, 16), let s = digits(17, 19),
              let fraction = c.count == 20 ? 0 : digits(20, c.count - 1),
              y >= 1970, (1...12).contains(m), (1...31).contains(d), h < 24, mi < 60, s < 60 else { return nil }
        // Days since 1970-01-01, proleptic Gregorian (days_from_civil); day 31 of a short month rolls over like the formatter.
        let year = m <= 2 ? y - 1 : y, era = year / 400, yoe = year - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + h * 3_600 + mi * 60 + s)
                    + Double(fraction) / [1, 1, 10, 100, 1_000][c.count - 20])
    }
}
