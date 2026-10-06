import Foundation

/// Amp: one JSON snapshot per thread, `threads/T-<id>.json` (also one folder deeper), rewritten in place as the thread
/// changes, so it is parsed whole again when its size, time or file changes.
/// - Turn: a user message with content other than tool results opens it; an assistant message's `state` decides the
///   rest: `streaming` runs, `complete` with tool uses waits on them, `complete` otherwise completes the turn,
///   `cancelled` or `error` interrupts it. A tool result whose `run.status` is `blocked-on-user` waits for the person.
/// - Tokens: `messages[].usage.outputTokens` at `usage.timestamp`; `usageLedger.events[]` (`toMessageId`,
///   `tokens.output`) for messages without usage. No per-call duration is written, so no speed is measured.
/// - Times: usage timestamps and user `meta.sentAt` (ms); the file's modification time is the newest record of any kind.
/// - Project: `env.initial.trees[0]` (`uri` file URL, `displayName`).
extension TokenLogFormat {
    static let amp = TokenLogFormat(files: { roots, discovery in
        func isThread(_ url: URL) -> Bool { url.pathExtension == "json" && url.lastPathComponent.hasPrefix("T-") }
        var found: [URL] = []
        for root in roots {
            for entry in discovery.children(root) {
                if isThread(entry) { found.append(entry) }
                else if entry.pathExtension.isEmpty { found.append(contentsOf: discovery.children(entry).filter(isThread)) }
            }
        }
        return discovery.recent(found)
    }, isLog: { path in
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("T-") && name.hasSuffix(".json")
    }, open: { AmpLogReader(url: $0) })
}

final class AmpLogReader: TokenLogReader {
    let url: URL
    private var stamp: String?
    private var turn = LogTurnState()
    private var threadID: String?
    private var model: String?
    private var cwd: String?
    /// The tree's display name, for a thread whose tree has no file URL.
    private var projectName: String?
    /// Snapshots past this size are left unread rather than parsed on every change.
    private static let maximumBytes = 67_108_864
    /// Tool runs that ended; any other status still runs.
    private static let finishedRuns: Set<String> = ["done", "error", "cancelled", "rejected-by-user"]

    init(url: URL) {
        self.url = url
        threadID = url.deletingPathExtension().lastPathComponent
    }

    func isRecent(at now: Date) -> Bool { turn.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard var reading = turn.reading(source: .amp, id: id, model: model, cwd: cwd, now: now) else { return [] }
        reading.sessionID = threadID
        if cwd == nil { reading.project = projectName }
        return [reading]
    }

    func read(tailLimit: Int, now: Date) {
        turn.clamp(to: now.addingTimeInterval(5))
        var info = stat()
        guard stat(url.path, &info) == 0 else { return }
        let current = "\(info.st_dev)-\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        guard current != stamp else { return }
        stamp = current
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        guard Int(info.st_size) <= Self.maximumBytes, let data = try? Data(contentsOf: url),
              let thread = LogFields.object(data) else { return }
        autoreleasepool { parse(thread, modified: min(modified, now.addingTimeInterval(5))) }
    }

    private func parse(_ thread: [String: Any], modified: Date) {
        let state = LogTurnState()
        var latestModel: String?
        threadID = LogFields.text(thread["id"]) ?? threadID
        if let tree = ((thread["env"] as? [String: Any])?["initial"] as? [String: Any]).flatMap({ ($0["trees"] as? [[String: Any]])?.first }) {
            if let uri = LogFields.text(tree["uri"]), let file = URL(string: uri), file.isFileURL { cwd = file.path }
            projectName = LogFields.text(tree["displayName"])
        }
        // Ledger outputs by message, for messages that carry no usage of their own.
        var ledger: [Int: [(tokens: Int, at: Date?, model: String?)]] = [:]
        for event in ((thread["usageLedger"] as? [String: Any])?["events"] as? [[String: Any]]) ?? [] {
            guard let message = LogFields.count(event["toMessageId"]),
                  let tokens = LogFields.count((event["tokens"] as? [String: Any])?["output"]) else { continue }
            ledger[message, default: []].append((tokens, LogFields.date(event["timestamp"]), LogFields.text(event["model"])))
        }
        for message in thread["messages"] as? [[String: Any]] ?? [] {
            let blocks = message["content"] as? [[String: Any]] ?? []
            switch message["role"] as? String {
            case "user":
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                if results.count < blocks.count {
                    state.begin(at: LogFields.milliseconds((message["meta"] as? [String: Any])?["sentAt"]))
                }
                for result in results {
                    guard let id = LogFields.text(result["toolUseID"]) ?? LogFields.text(result["tool_use_id"]) else { continue }
                    let status = (result["run"] as? [String: Any])?["status"] as? String
                    if status == "blocked-on-user" { state.startRequest(id, at: nil) }
                    else if let status, Self.finishedRuns.contains(status) {
                        state.finishRequest(id)
                        state.finishTool(id, at: nil)
                    }
                }
            case "assistant":
                let usage = message["usage"] as? [String: Any]
                let at = LogFields.date(usage?["timestamp"])
                state.resume(at: at)
                for block in blocks where block["type"] as? String == "tool_use" {
                    if let id = LogFields.text(block["id"]) { state.startTool(id, name: LogFields.text(block["name"]), at: at) }
                }
                if let usage {
                    latestModel = LogFields.text(usage["model"]) ?? latestModel
                    if let tokens = LogFields.count(usage["outputTokens"]) { state.addOutput(tokens, at: at) }
                } else if let id = LogFields.count(message["messageId"]) {
                    for event in ledger[id] ?? [] {
                        latestModel = event.model ?? latestModel
                        state.addOutput(event.tokens, at: event.at)
                    }
                }
                let messageState = message["state"] as? [String: Any]
                switch messageState?["type"] as? String {
                case "streaming": state.setState(state.hasPendingTools ? .tool : .output, at: at)
                case "cancelled", "error": state.close(.interrupted, at: at, model: latestModel)
                case "complete":
                    if !state.hasPendingTools && messageState?["stopReason"] as? String != "tool_use" {
                        state.close(.complete, at: at, model: latestModel)
                    }
                default: break
                }
            default: break
            }
        }
        state.logged(modified)
        // A thread with content but no recorded times still shows, as of its last write.
        if state.lastActivity == nil, (thread["messages"] as? [Any])?.isEmpty == false { state.touch(modified) }
        model = latestModel
        turn = state
    }
}
