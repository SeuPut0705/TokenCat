import Foundation

/// A session's title as its client generated or the person renamed it: Claude Code `custom-title`/`ai-title`/`summary`,
/// Codex thread names, OpenCode `session.title`, omp `title_change`/Pi `session_info`, Gemini CLI `summary`, Qwen Code
/// `custom_title`, Copilot CLI `name`/`summary`, Amp thread `title`, a generated or renamed Droid `session_start.title`.
/// Never a prompt: a client that only copies the first message (Cline, Roo Code, Kilo Code, a Droid title not yet
/// generated) has none. Kept in memory on the reading only; never stored, logged or sent.
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
/// One index per file, shared by every rollout reader of that Codex home.
final class CodexThreadNames {
    private static let lock = NSLock()
    private static var indexes: [String: CodexThreadNames] = [:]
    private let tail: LogLineTail
    private var names: [String: String] = [:]

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

    /// Reads lines appended since the last call; a stat when nothing changed.
    func refresh() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        tail.read(tailLimit: 4_194_304, reset: { names.removeAll() }) { line in
            guard let record = LogFields.object(line), let id = LogFields.text(record["id"])?.lowercased(),
                  let name = SessionTitle.clean(record["thread_name"]) else { return }
            names[id] = name
        }
    }

    func name(for thread: String?) -> String? {
        guard let thread else { return nil }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return names[thread.lowercased()]
    }
}
