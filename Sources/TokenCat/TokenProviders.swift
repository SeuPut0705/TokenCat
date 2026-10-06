import Foundation

/// The provider registry: one entry per client TokenCat recognises, in `TokenSource` order.
/// Adding a client takes one parser file (a `TokenLogFormat` whose `open` returns a `TokenLogReader`) and its `format:` here.
/// - `roots`: the client's data folders, environment overrides first. A client counts as detected when one exists; only
///   existing roots are listed, and `TokenTracker.watchedDirectories` names the roots of clients that have a format.
/// - `format` nil: detected, never read — no rows, counts or speeds. Allowed only while that client's parser is pending.
/// Telemetry, live limits and the status line bridge stay with `TokenSource.telemetryClients` (Codex and Claude Code).
/// Windows mirrors this as `TokenProvider.All` (TokenProviders.cs).
struct TokenProvider {
    let source: TokenSource
    let roots: (_ home: URL, _ environment: [String: String]) -> [URL]
    let format: TokenLogFormat?

    static let all: [TokenProvider] = [
        TokenProvider(source: .codex, roots: { home, _ in [home.appendingPathComponent(".codex/sessions")] }, format: .codex),
        TokenProvider(source: .claude, roots: { home, _ in [home.appendingPathComponent(".claude/projects")] }, format: .claude),
        TokenProvider(source: .opencode, roots: { home, env in
            [env.path("OPENCODE_DB")?.deletingLastPathComponent(), dataHome(home, env).appendingPathComponent("opencode")].compactMap { $0 }
        }, format: nil),
        TokenProvider(source: .gemini, roots: { home, env in
            [(env.path("GEMINI_CLI_HOME") ?? home).appendingPathComponent(".gemini/tmp")]
        }, format: nil),
        TokenProvider(source: .qwen, roots: { home, _ in [home.appendingPathComponent(".qwen/projects")] }, format: nil),
        TokenProvider(source: .copilot, roots: { home, env in
            [(env.path("COPILOT_HOME") ?? home.appendingPathComponent(".copilot")).appendingPathComponent("session-state")]
        }, format: nil),
        TokenProvider(source: .amp, roots: { home, env in [dataHome(home, env).appendingPathComponent("amp/threads")] }, format: nil),
        TokenProvider(source: .cline, roots: { home, _ in
            let support = home.appendingPathComponent("Library/Application Support")
            return editors.flatMap { editor in
                vscodeExtensions.map { support.appendingPathComponent("\(editor)/User/globalStorage/\($0)/tasks") }
            } + [home.appendingPathComponent(".cline/data/sessions")]
        }, format: nil),
        TokenProvider(source: .omp, roots: { home, _ in
            [home.appendingPathComponent(".omp/agent/sessions"), home.appendingPathComponent(".pi/agent/sessions")]
        }, format: nil),
        TokenProvider(source: .droid, roots: { home, _ in [home.appendingPathComponent(".factory/sessions")] }, format: nil),
    ]

    /// VS Code family editors whose globalStorage may hold Cline, Roo Code or Kilo Code tasks.
    static let editors = ["Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf"]
    static let vscodeExtensions = ["saoudrizwan.claude-dev", "rooveterinaryinc.roo-cline", "kilocode.kilo-code"]

    /// `$XDG_DATA_HOME`, else ~/.local/share (OpenCode and Amp use it on macOS too).
    static func dataHome(_ home: URL, _ environment: [String: String]) -> URL {
        environment.path("XDG_DATA_HOME") ?? home.appendingPathComponent(".local/share")
    }

    func existingRoots(home: URL, environment: [String: String]) -> [URL] {
        var seen = Set<String>()
        return roots(home, environment).filter { seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Clients whose logs TokenCat reads, in registry order.
    static var readSources: [TokenSource] { all.filter { $0.format != nil }.map(\.source) }

    /// Their titles for the empty state: "Codex·Claude Code" and "Codex or Claude Code" ("A, B or C" for more).
    static var readTitles: (korean: String, english: String) {
        let titles = readSources.map(\.title)
        let english = titles.count > 1 ? titles.dropLast().joined(separator: ", ") + " or " + titles.last! : titles.joined()
        return (titles.joined(separator: "·"), english)
    }

    /// Their default roots with "~" for home: "~/.codex/sessions · ~/.claude/projects".
    static func readRootsText(home: URL) -> String {
        let prefix = home.path + "/"
        return all.filter { $0.format != nil }.flatMap { $0.roots(home, [:]) }
            .map { $0.path.hasPrefix(prefix) ? "~/" + $0.path.dropFirst(prefix.count) : $0.path }.joined(separator: " · ")
    }
}

/// How a client's logs are listed and read. Every closure runs on the tracker's queue.
struct TokenLogFormat {
    /// Logs worth tracking under the client's existing `roots`. Rank and cap them with `discovery.recent`, so every listed
    /// path is also `known` (a write to a log the caps left out then waits for the 5 s rescan instead of forcing one).
    let files: (_ roots: [URL], _ discovery: TokenDiscovery) -> [URL]
    /// Whether a path from a file event is a log `files` would list; an untracked one triggers discovery on the next sample.
    let isLog: (_ path: String) -> Bool
    /// The reader for one listed log, kept while discovery lists it or `isRecent` holds.
    let open: (_ url: URL) -> TokenLogReader
}

/// Reads one tracked log (a file or a database) and reports its sessions. Never stores transcript text.
protocol TokenLogReader: AnyObject {
    /// Called once per sample: read what changed since the last call. `tailLimit` bounds the first read of a large log.
    func read(tailLimit: Int, now: Date)
    /// The log's sessions now; empty until something countable was read. `id` is the stable row id
    /// ("<source>:<path relative to home>"); a log holding several sessions appends "#<session>" for each row.
    func readings(id: String, now: Date) -> [TokenReading]
    /// Keeps the reader past the discovery caps: an open turn, or a log written within the hour.
    func isRecent(at now: Date) -> Bool
}

/// Discovery helpers shared by every format; one per discovery pass.
final class TokenDiscovery {
    let now: Date
    /// Every log the caps were applied to, inside them or not.
    private(set) var known = Set<String>()

    init(now: Date) { self.now = now }

    /// Visible entries of `directory`; empty when it is missing or unreadable.
    func children(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    /// The 32 newest, plus up to 32 more modified since `cutoff` (the retention hour), so a cold start opens them too.
    func recent(_ urls: [URL], keepingSince cutoff: Date = .distantFuture) -> [URL] {
        let dated: [(url: URL, modified: Date)] = urls
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        known.formUnion(dated.map(\.url.path))
        return dated.sorted { $0.modified > $1.modified }.enumerated()
            .filter { $0.offset < 32 || ($0.offset < 64 && $0.element.modified >= cutoff) }.map { $0.element.url }
    }
}

private extension Dictionary where Key == String, Value == String {
    /// A non-empty environment value as a file URL.
    func path(_ key: String) -> URL? {
        self[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}
