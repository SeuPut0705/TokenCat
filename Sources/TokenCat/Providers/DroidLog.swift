import Foundation

/// Factory Droid: `sessions/<project-slug>/<session>.jsonl` (older builds: directly in `sessions/`) with a
/// `<session>.settings.json` beside it.
/// - JSONL: a `session_start` header (`id`, `cwd`), then `message` records `{timestamp, message: {role, content[]}}` with
///   text, thinking, tool_use and tool_result blocks. Messages marked `visibility: llm_only` are injected context.
/// - Turn: the person's message opens it, an assistant message with tool uses waits on them, one with text and no tool
///   use completes it (a later assistant message reopens it).
/// - Tokens: the settings file's `tokenUsage.outputTokens` is the session total. Its growth between reads is logged
///   output at the file's write time; the first total read is a baseline, so a turn counts only when its start came
///   after a known total. There is no per-message usage or duration, so no speed is measured.
/// - Model and effort: the settings file's `model` and `reasoningEffort`.
/// - Title: `session_start.title` once Droid generated it (`sessionTitleAutoStage`) or the person renamed it
///   (`isSessionTitleManuallySet`); before that it holds the first message's opening, which is never read as a title.
extension TokenLogFormat {
    static let droid = TokenLogFormat(files: { roots, discovery in
        var found: [URL] = []
        for root in roots {
            for entry in discovery.children(root) {
                if entry.pathExtension == "jsonl" { found.append(entry) }
                else if discovery.isFolder(entry) { found.append(contentsOf: discovery.children(entry).filter { $0.pathExtension == "jsonl" }) }
            }
        }
        return discovery.recent(found)
    }, isLog: { $0.hasSuffix(".jsonl") }, open: { DroidLogReader(url: $0) })
}

final class DroidLogReader: TokenLogReader {
    private let tail: LogLineTail
    private let settingsURL: URL
    private var settingsStamp: String?
    private var turn = LogTurnState()
    private var sessionID: String?
    private var cwd: String?
    private var model: String?
    private var effort: String?
    private var title: String?
    private var headerStamp: String?
    /// The settings file's output total at its latest read; nil until one was read.
    private var outputTotal: Int?

    init(url: URL) {
        tail = LogLineTail(url: url)
        settingsURL = url.deletingPathExtension().appendingPathExtension("settings.json")
        sessionID = url.deletingPathExtension().lastPathComponent
    }

    func isRecent(at now: Date) -> Bool { turn.isRecent(at: now) }

    func readings(id: String, now: Date) -> [TokenReading] {
        guard var reading = turn.reading(source: .droid, id: id, model: model, cwd: cwd, now: now) else { return [] }
        reading.sessionID = sessionID
        reading.effort = effort
        reading.title = title
        return [reading]
    }

    func read(tailLimit: Int, now: Date) {
        turn.clamp(to: now.addingTimeInterval(5))
        let initial = tail.modified == nil
        tail.read(tailLimit: tailLimit, reset: {
            turn = LogTurnState()
            outputTotal = nil
            settingsStamp = nil
        }) { line in
            consume(line)
        }
        readHeader(skipped: initial && tail.skippedHead)
        // After the log, so a turn opened in this read starts from the total before its output.
        readSettings(now: now)
    }

    /// Droid rewrites the `session_start` line in place to set the title (a rename keeps the file's times), so that line is
    /// read again whenever the log's file, size or time changed. When the first tail skipped it, it also names the id and cwd.
    private func readHeader(skipped: Bool) {
        var info = stat()
        guard stat(tail.url.path, &info) == 0 else { return }
        let current = "\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        guard current != headerStamp else { return }
        headerStamp = current
        guard let header = tail.firstLine(limit: 16_384), let record = LogFields.object(header),
              record["type"] as? String == "session_start" else { return }
        if skipped {
            sessionID = LogFields.text(record["id"]) ?? sessionID
            cwd = LogFields.text(record["cwd"]) ?? cwd
        }
        title = Self.title(record)
    }

    /// A generated or renamed title only: Droid starts every session titled with its first message's opening.
    static func title(_ start: [String: Any]) -> String? {
        guard start["isSessionTitleManuallySet"] as? Bool == true || start["sessionTitleAutoStage"] is String else { return nil }
        return SessionTitle.clean(start["title"])
    }

    private func consume(_ data: Data) {
        guard let record = LogFields.object(data) else { return }
        let date = LogFields.date(record["timestamp"])
        turn.logged(date)
        switch record["type"] as? String {
        case "session_start":
            sessionID = LogFields.text(record["id"]) ?? sessionID
            cwd = LogFields.text(record["cwd"]) ?? cwd
        case "message":
            guard let message = record["message"] as? [String: Any] else { return }
            let content = message["content"]
            let blocks = content as? [[String: Any]] ?? []
            switch message["role"] as? String {
            case "user":
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                for result in results {
                    if let id = LogFields.text(result["tool_use_id"]) { turn.finishTool(id, at: date) }
                }
                let prompt = content is String || results.count < blocks.count
                if prompt, message["visibility"] as? String != "llm_only" { turn.begin(at: date, whole: outputTotal != nil) }
            case "assistant":
                turn.resume(at: date)
                let tools = blocks.filter { $0["type"] as? String == "tool_use" }
                for tool in tools {
                    if let id = LogFields.text(tool["id"]) { turn.startTool(id, name: LogFields.text(tool["name"]), at: date) }
                }
                if tools.isEmpty, !turn.hasPendingTools, blocks.contains(where: { $0["type"] as? String == "text" }) {
                    turn.close(.complete, at: date, model: model)
                } else if tools.isEmpty {
                    turn.setState(turn.hasPendingTools ? .tool : .working, at: date)
                }
            default: break
            }
        default: break
        }
    }

    private func readSettings(now: Date) {
        var info = stat()
        guard stat(settingsURL.path, &info) == 0 else { return }
        let current = "\(info.st_ino)-\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        guard current != settingsStamp else { return }
        settingsStamp = current
        guard info.st_size <= 1_048_576, let data = try? Data(contentsOf: settingsURL),
              let settings = LogFields.object(data) else { return }
        let written = min(now.addingTimeInterval(5), Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                                                         + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9))
        model = Self.modelName(settings["model"]) ?? model
        if let level = TokenLogParser.label(settings["reasoningEffort"]) { effort = level == "none" ? nil : level }
        guard let total = LogFields.count((settings["tokenUsage"] as? [String: Any])?["outputTokens"]) else { return }
        if let previous = outputTotal, total > previous {
            turn.logged(written)
            turn.addOutput(total - previous, at: written)
        }
        outputTotal = total
    }

    /// Bring-your-own models read `custom:<name>-[<Provider>]-<n>`; the name alone is shown.
    static func modelName(_ value: Any?) -> String? {
        guard var name = LogFields.text(value) else { return nil }
        if name.hasPrefix("custom:") { name.removeFirst(7) }
        if let bracket = name.range(of: "-[", options: .backwards), name[bracket.upperBound...].contains("]") {
            name = String(name[..<bracket.lowerBound])
        }
        return name.isEmpty ? nil : name
    }
}
