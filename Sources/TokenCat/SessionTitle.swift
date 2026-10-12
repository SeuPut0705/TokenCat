import Foundation

/// A session's title as its client generated or the person renamed it: Claude Code `custom-title`/`ai-title`/`summary`,
/// Codex thread names, OpenCode/Kilo Code/MiMo Code `session.title`, omp `title_change`/Pi `session_info`, Gemini CLI
/// `summary`, Qwen Code `custom_title`, Copilot CLI `name`/`summary`, Amp thread `title`, a generated or renamed Droid
/// `session_start.title`, the Cursor composer `name`, Grok `generated_title`, a Hermes `title` from the model or the person,
/// the OpenClaw `label`/`displayName`, a generated, recipe or renamed Goose `name`, a generated or custom Kimi Code `title`.
/// Never a prompt: a client that only copies the first message (Cline, Roo Code, Kilo Code's extension, Zoo Code, IBM Bob,
/// kimi-cli, a Droid title not yet generated, a Hermes `derived` title, MiMo `fallback` titles, a Grok title copying the
/// first prompt, a Goose session on a CLI or ACP agent provider) has none. Kept in memory on the reading only; never stored,
/// logged or sent.
enum SessionTitle {
    /// Longer titles end in "…" at this many characters; the rows truncate further to fit.
    static let maximumLength = 80

    /// One line of at most `maximumLength` characters: control characters and line breaks become spaces, invisible format
    /// characters (bidi overrides, BOM) are dropped, runs of white space collapse. Nil when nothing is left.
    static func clean(_ value: Any?) -> String? {
        guard var raw = value as? String, !raw.isEmpty else { return nil }
        // A hostile value never costs more than a few kilobytes of work.
        if raw.utf8.count > 4_096 { raw = String(raw.prefix(1_024)) }
        var scalars = String.UnicodeScalarView()
        var gap = false
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                gap = true
                continue
            // The zero-width joiner holds emoji sequences together; other format characters only reorder or hide text.
            case .format where scalar.value != 0x200D:
                continue
            default: break
            }
            if gap, !scalars.isEmpty { scalars.append(" ") }
            gap = false
            scalars.append(scalar)
        }
        let text = String(scalars)
        guard !text.isEmpty else { return nil }
        guard text.count > maximumLength else { return text }
        var cut = String(text.prefix(maximumLength - 1))
        while cut.last == " " { cut.removeLast() }
        return cut + "…"
    }
}

/// Codex thread names: `<CODEX_HOME>/session_index.jsonl`, append-only `{id, thread_name, updated_at}` lines written on
/// every rename or generated name (the rollout's `thread_name_updated` event is not persisted). The newest non-empty name
/// of an id wins, as in Codex's own lookup; a rewrite that removes names (the file shrinks or is replaced) is read again.
/// One index per file, shared by every rollout reader of that Codex home. Names are kept for the threads a reader asked
/// for within `sweepInterval`, plus the `unaskedLimit` newest others; an older id asked for again is looked up in the file.
final class CodexThreadNames {
    private static let lock = NSLock()
    private static var indexes: [String: CodexThreadNames] = [:]
    static let unaskedLimit = 2_048
    static let sweepInterval: TimeInterval = 600
    private static let tailLimit = 4_194_304
    private let tail: LogLineTail
    /// Threads a reader asked for, with their name (nil: none recorded yet).
    private var asked: [String: String?] = [:]
    private var askedSinceSweep = Set<String>()
    private var unasked = RecentKeys<String>(limit: CodexThreadNames.unaskedLimit)
    /// Whether `unasked` ever forgot a name, so a miss may be an evicted one rather than a thread without a name.
    private var evicted = false
    /// Readers that are no longer asking let their thread go at the next sweep.
    private var sweptAt = ProcessInfo.processInfo.systemUptime

    private init(url: URL) { tail = LogLineTail(url: url) }

    /// The index beside the `sessions` folder holding a rollout (`sessions/YYYY/MM/DD/rollout-….jsonl`).
    static func index(forRollout rollout: URL) -> CodexThreadNames {
        var home = rollout
        for _ in 0..<5 { home.deleteLastPathComponent() }
        let url = home.appendingPathComponent("session_index.jsonl")
        lock.lock()
        defer { lock.unlock() }
        if let index = indexes[url.path] { return index }
        let index = CodexThreadNames(url: url)
        indexes[url.path] = index
        return index
    }

    /// Names held in memory (asked and unasked), for the eviction check.
    var heldNames: Int { Self.lock.withLock { asked.count + unasked.count } }

    /// Reads lines appended since the last call; a stat when nothing changed.
    func refresh() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - sweptAt >= Self.sweepInterval || uptime < sweptAt { sweepLocked(at: uptime) }
        tail.read(tailLimit: Self.tailLimit, reset: {
            for id in asked.keys { asked[id] = .some(nil) }
            unasked.removeAll()
            evicted = false
        }) { line in
            guard let (id, name) = Self.entry(line) else { return }
            if asked[id] != nil { asked[id] = name; return }
            if unasked.count >= Self.unaskedLimit, !unasked.contains(id) { evicted = true }
            unasked.set(id, name)
        }
    }

    func name(for thread: String?) -> String? {
        guard let thread else { return nil }
        let id = thread.lowercased()
        Self.lock.lock()
        defer { Self.lock.unlock() }
        askedSinceSweep.insert(id)
        if let known = asked[id] { return known }
        var name = unasked[id]
        if name == nil, evicted { name = lookUp(id) }
        asked[id] = .some(name)
        return name
    }

    /// Threads no reader asked for since the previous sweep go back to being unasked (or are forgotten).
    func sweep() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        sweepLocked(at: ProcessInfo.processInfo.systemUptime)
    }

    private func sweepLocked(at uptime: TimeInterval) {
        for (id, name) in asked where !askedSinceSweep.contains(id) {
            asked[id] = nil
            if let name {
                if unasked.count >= Self.unaskedLimit, !unasked.contains(id) { evicted = true }
                unasked.set(id, name)
            }
        }
        askedSinceSweep.removeAll(keepingCapacity: true)
        sweptAt = uptime
    }

    private static func entry(_ line: Data) -> (id: String, name: String)? {
        guard let record = LogFields.object(line), let id = LogFields.text(record["id"])?.lowercased(),
              let name = SessionTitle.clean(record["thread_name"]) else { return nil }
        return (id, name)
    }

    /// The newest name of `id` within the index's last `tailLimit` bytes (the window the first read covers).
    private func lookUp(_ id: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: tail.url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(Self.tailLimit) ? size - UInt64(Self.tailLimit) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let needle = Data(id.utf8)
        var name: String?
        var lines = LogLineAssembler()
        lines.dropping = start > 0
        lines.consume(data) { line in
            // Ids are written in lower case by Codex; the full parse confirms the match.
            guard line.range(of: needle) != nil || line.range(of: Data(id.uppercased().utf8)) != nil,
                  let entry = Self.entry(line), entry.id == id else { return }
            name = entry.name
        }
        return name
    }
}
